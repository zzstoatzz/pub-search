//! Autonomous bulk-mirror classifier — the labeler's brain.
//!
//! The labeler watches the firehose and labels on its own: every ingested
//! document is fed here via observe(), which keeps a rolling per-DID aggregate
//! in its OWN SQLite (never turso, never the frozen replica, never blocks the
//! firehose). When a DID crosses a volume floor it is scored in-process; if it
//! looks like a machine-generated registry/feed mirror, the labeler emits a
//! signed `machine-generated` account label — no human in the loop.
//!
//! Scoring mirrors scripts/classify-bulk-mirror (validated offline): the
//! decisive axis is authorship/content SHAPE (templated titles, thin/empty
//! content), NOT volume — volume only corroborates, because the corpus's
//! highest-volume authors are real humans. A mislabel is corrected by a
//! negation (see labeler.emit neg=true), so autonomous emission is safe.

const std = @import("std");
const zqlite = @import("zqlite");
const logfire = @import("logfire");
const labeler = @import("../labeler.zig");
const db = @import("../db.zig");

const http = std.http;
const json = std.json;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.classifier);

// tuned against the known keep/flag set. THRESHOLD is conservative (offline
// separation put flags at 0.52-0.81, real humans <0.27) because emission is
// autonomous and there's no curation veto in the firehose path.
const FLOOR: i64 = 50; // min docs before a DID can be judged
const EVAL_EVERY: i64 = 25; // re-score every N docs past the floor until labeled
// Precision comes from the signal fixes (date/empty/non-ASCII titles score ~0.3),
// not the threshold — so 0.50 catches genuine mirrors (transit feeds ~0.54)
// while staying FP-safe. The curation veto is the backstop for prolific humans.
const THRESHOLD: f64 = 0.50;
// bump when scoring logic OR threshold changes → bootstrap negates old labels +
// re-scores the whole corpus from a clean slate. v2 = precision fix (content-word
// scaffold only, curation veto). v3 = threshold 0.55→0.50. v4 = model-pass gate
// (heuristic flags → LLM confirms content is machine-generated before emit).
const SCORING_VERSION: i64 = 6; // v6: rename label bulk-mirror → machine-generated (re-emit)

// review pipeline states. The heuristic is a cheap PRE-FILTER: it never emits
// directly (titles can't tell a branded real blog from a registry mirror). It
// flags PENDING; a background worker reads sample CONTENT, asks an LLM, and only
// then emits. So a false positive from the heuristic costs an LLM call, not a
// mislabeled human.
const STATE_OBSERVING: i64 = 0;
const STATE_PENDING: i64 = 1; // heuristic flagged; awaiting model review
const STATE_LABELED: i64 = 2; // model confirmed machine-generated → emitted
const STATE_REJECTED: i64 = 3; // model said human → not labeled
const STATE_VETOED: i64 = 4; // had curation → never labeled
const MAX_REVIEW_ATTEMPTS: i64 = 5; // give up after this many inconclusive reviews
// the model-pass runs on co/core (cocore.dev) — an AT-Protocol-native, OpenAI-
// compatible decentralized inference exchange. Fitting: the labeler is an AT
// Proto thing, so its content judge runs on AT-Proto-native inference.
const REVIEW_MODEL = "mlx-community/Qwen2.5-7B-Instruct-4bit";
const COCORE_URL = "https://console.cocore.dev/api/v1/chat/completions";
const SAMPLE_CAP: i64 = 64; // normalized titles kept per DID for template scoring

var g_conn: ?zqlite.Conn = null;

const STOPWORDS = [_][]const u8{
    "the", "a",   "an",   "and", "or",   "but", "of",   "to", "in",  "on", "for",  "with",
    "at",  "by",  "from", "is",  "are",  "was", "were", "be", "as",  "it", "this", "that",
    "i",   "you", "we",   "my",  "your", "our", "me",   "no", "not", "do",
};

fn isStopword(w: []const u8) bool {
    for (STOPWORDS) |s| if (std.mem.eql(u8, s, w)) return true;
    return false;
}

/// Open the author-stats db (separate file from labels.db; this is working
/// state, not emitted labels). No-op safe to call once at boot.
pub fn init() void {
    const path: [*:0]const u8 = if (std.c.getenv("CLASSIFIER_DB")) |p| @ptrCast(p) else "/data/author-stats.db";
    const conn = zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite) catch |err| {
        logfire.err("classifier: open failed: {s}", .{@errorName(err)});
        return;
    };
    conn.execNoArgs("PRAGMA journal_mode=WAL") catch {};
    conn.execNoArgs("PRAGMA busy_timeout=5000") catch {};
    conn.execNoArgs(
        \\CREATE TABLE IF NOT EXISTS author_stats (
        \\  did TEXT PRIMARY KEY,
        \\  doc_count INTEGER NOT NULL DEFAULT 0,
        \\  len_sum INTEGER NOT NULL DEFAULT 0,
        \\  empty_titles INTEGER NOT NULL DEFAULT 0,
        \\  digit_titles INTEGER NOT NULL DEFAULT 0,
        \\  title_sample TEXT NOT NULL DEFAULT '',
        \\  sample_count INTEGER NOT NULL DEFAULT 0,
        \\  labeled INTEGER NOT NULL DEFAULT 0
        \\)
    ) catch |err| {
        logfire.err("classifier: schema failed: {s}", .{@errorName(err)});
        return;
    };
    conn.execNoArgs("CREATE TABLE IF NOT EXISTS classifier_meta (k TEXT PRIMARY KEY, v INTEGER NOT NULL)") catch {};
    // review-pipeline state (added after the initial schema; ALTER is a no-op if
    // the column already exists).
    conn.execNoArgs("ALTER TABLE author_stats ADD COLUMN state INTEGER NOT NULL DEFAULT 0") catch {};
    conn.execNoArgs("ALTER TABLE author_stats ADD COLUMN review_attempts INTEGER NOT NULL DEFAULT 0") catch {};
    conn.execNoArgs("ALTER TABLE author_stats ADD COLUMN reason TEXT NOT NULL DEFAULT ''") catch {};
    g_conn = conn;
    logfire.info("classifier: author-stats ready (floor={d} threshold={d:.2})", .{ FLOOR, THRESHOLD });
}

/// Feed one ingested document. Cheap upsert; scores + maybe emits when a DID
/// crosses the floor. Called from the firehose path — must never block on
/// anything but local sqlite.
pub fn observe(did: []const u8, title: []const u8, content: []const u8) void {
    observeLen(did, title, content.len);
}

/// One-time backfill: feed the existing corpus through the aggregate so the
/// classifier evaluates every author already indexed (not just ones that
/// publish after deploy). Reads the local replica (frozen, no turso); pulls only
/// did/title/LENGTH(content), never the content blobs. Idempotent via a marker.
/// Runs once, in a background thread.
pub fn bootstrap() void {
    const conn = g_conn orelse return;
    if (getMeta(conn, "scoring_version") == SCORING_VERSION) return;
    const local = db.getLocalDbRaw() orelse return;
    if (!local.isReady()) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // scoring changed since last bootstrap: negate every label we previously
    // emitted, so the corrected scoring starts from a clean slate (otherwise a
    // now-below-threshold author would keep a stale positive label). No-op on
    // the very first boot (nothing labeled yet).
    {
        var prev: std.ArrayList([]const u8) = .empty;
        var rows = conn.rows("SELECT did FROM author_stats WHERE labeled = 1", .{}) catch return;
        while (rows.next()) |row| prev.append(a, a.dupe(u8, row.text(0)) catch continue) catch {};
        rows.deinit();
        for (prev.items) |did| _ = labeler.emit(did, labeler.LABEL_MACHINE_GENERATED, true) catch {};
        if (prev.items.len > 0)
            logfire.info("classifier: cleared {d} prior labels for re-scoring (v{d})", .{ prev.items.len, SCORING_VERSION });
        conn.execNoArgs("DELETE FROM author_stats") catch {};
    }

    const Entry = struct { did: []const u8, title: []const u8, len: usize };
    var entries: std.ArrayList(Entry) = .empty;

    // materialize first so we don't hold a replica read connection across the
    // (slower) per-row upserts below.
    {
        var rows = local.query("SELECT did, title, LENGTH(content) FROM documents", .{}) catch |err| {
            logfire.err("classifier: bootstrap query failed: {s}", .{@errorName(err)});
            return;
        };
        defer rows.deinit();
        while (rows.next()) |row| {
            entries.append(a, .{
                .did = a.dupe(u8, row.text(0)) catch continue,
                .title = a.dupe(u8, row.text(1)) catch continue,
                .len = @intCast(@max(row.int(2), 0)),
            }) catch continue;
        }
    }

    for (entries.items) |e| observeLen(e.did, e.title, e.len);
    setMeta(conn, "scoring_version", SCORING_VERSION);
    logfire.info("classifier: bootstrap (re)scored {d} existing docs at v{d}", .{ entries.items.len, SCORING_VERSION });
}

fn getMeta(conn: zqlite.Conn, key: []const u8) i64 {
    const row = (conn.row("SELECT v FROM classifier_meta WHERE k = ?", .{key}) catch return 0) orelse return 0;
    defer row.deinit();
    return row.int(0);
}

fn setMeta(conn: zqlite.Conn, key: []const u8, v: i64) void {
    conn.exec("INSERT OR REPLACE INTO classifier_meta (k, v) VALUES (?, ?)", .{ key, v }) catch {};
}

fn observeLen(did: []const u8, title: []const u8, content_len: usize) void {
    const conn = g_conn orelse return;

    var norm_buf: [256]u8 = undefined;
    const norm = normalizeTitle(title, &norm_buf);
    const has_digit: i64 = if (hasDigit(title)) 1 else 0;
    const is_empty: i64 = if (std.mem.trim(u8, title, " \t\n").len == 0) 1 else 0;

    // append the normalized title to the sample (newline-joined) until capped.
    conn.exec(
        \\INSERT INTO author_stats (did, doc_count, len_sum, empty_titles, digit_titles, title_sample, sample_count)
        \\VALUES (?, 1, ?, ?, ?, ?, 1)
        \\ON CONFLICT(did) DO UPDATE SET
        \\  doc_count = doc_count + 1,
        \\  len_sum = len_sum + excluded.len_sum,
        \\  empty_titles = empty_titles + excluded.empty_titles,
        \\  digit_titles = digit_titles + excluded.digit_titles,
        \\  title_sample = CASE WHEN sample_count < ? THEN title_sample || char(10) || ? ELSE title_sample END,
        \\  sample_count = CASE WHEN sample_count < ? THEN sample_count + 1 ELSE sample_count END
    , .{ did, @as(i64, @intCast(content_len)), is_empty, has_digit, norm, SAMPLE_CAP, norm, SAMPLE_CAP }) catch |err| {
        log.debug("observe upsert: {s}", .{@errorName(err)});
        return;
    };

    maybeEvaluate(conn, did);
}

fn maybeEvaluate(conn: zqlite.Conn, did: []const u8) void {
    const row = (conn.row(
        "SELECT doc_count, len_sum, empty_titles, digit_titles, title_sample, labeled FROM author_stats WHERE did = ?",
        .{did},
    ) catch return) orelse return;
    defer row.deinit();

    const doc_count = row.int(0);
    const labeled = row.int(5) != 0;
    if (labeled or doc_count < FLOOR) return;
    if (@rem(doc_count, EVAL_EVERY) != 0) return; // only re-score on cadence

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const stats = Stats{
        .doc_count = doc_count,
        .len_sum = row.int(1),
        .empty_titles = row.int(2),
        .digit_titles = row.int(3),
        .sample = row.text(4),
    };
    const score = stats.score(arena.allocator());
    if (score < THRESHOLD) return;

    // curation veto: any recommends/subscriptions → never label (human signal a
    // mirror won't have). Decided; stop re-scoring.
    if (hasCuration(did)) {
        setDecided(conn, did, STATE_VETOED);
        logfire.info("classifier: vetoed {s} (score={d:.3} but has curation)", .{ did, score });
        return;
    }

    // the heuristic NEVER emits directly — it can't tell a branded real blog from
    // a registry mirror. Flag for the model-pass; the review worker reads sample
    // content, asks an LLM, and emits only on confirmation.
    setDecided(conn, did, STATE_PENDING);
    logfire.info("classifier: queued {s} for model review (score={d:.3} docs={d})", .{ did, score, doc_count });
}

/// The account's site domain (base_path) from the replica — these are
/// standard.site/leaflet publishers, so the domain (prideraiser.org) is the
/// human identity, not a bsky handle (which getProfiles can't resolve).
fn authorSite(allocator: Allocator, did: []const u8) ?[]const u8 {
    const local = db.getLocalDbRaw() orelse return null;
    if (!local.isReady()) return null;
    var rows = local.query("SELECT base_path FROM documents WHERE did = ? AND base_path != '' LIMIT 1", .{did}) catch return null;
    defer rows.deinit();
    if (rows.next()) |row| {
        const bp = row.text(0);
        if (bp.len > 0) return allocator.dupe(u8, bp) catch null;
    }
    return null;
}

fn stateName(s: i64) []const u8 {
    return switch (s) {
        STATE_PENDING => "pending",
        STATE_LABELED => "labeled",
        STATE_REJECTED => "rejected",
        STATE_VETOED => "vetoed",
        else => "observing",
    };
}

/// Read-only admin summary: counts by state + every decided author (state != 0)
/// with its score and a few normalized title patterns (the "why"). JSON for the
/// /labels heads-up page. caller owns the result.
pub fn writeSummaryJson(allocator: Allocator) ![]u8 {
    const conn = g_conn orelse return allocator.dupe(u8, "{\"counts\":{},\"authors\":[]}");

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var jw: json.Stringify = .{ .writer = &out.writer, .options = .{} };

    try jw.beginObject();

    // counts by state
    var counts = [_]i64{0} ** 5;
    {
        var r = try conn.rows("SELECT state, COUNT(*) FROM author_stats GROUP BY state", .{});
        defer r.deinit();
        while (r.next()) |row| {
            const s = row.int(0);
            if (s >= 0 and s < 5) counts[@intCast(s)] = row.int(1);
        }
    }
    try jw.objectField("counts");
    try jw.beginObject();
    inline for (.{ .{ "observing", STATE_OBSERVING }, .{ "pending", STATE_PENDING }, .{ "labeled", STATE_LABELED }, .{ "rejected", STATE_REJECTED }, .{ "vetoed", STATE_VETOED } }) |pair| {
        try jw.objectField(pair[0]);
        try jw.write(counts[pair[1]]);
    }
    try jw.endObject();

    // decided authors (labeled first, then pending, vetoed, rejected)
    try jw.objectField("authors");
    try jw.beginArray();
    var r = try conn.rows(
        \\SELECT did, doc_count, len_sum, empty_titles, digit_titles, title_sample, state, reason
        \\FROM author_stats WHERE state != 0
        \\ORDER BY CASE state WHEN 2 THEN 0 WHEN 1 THEN 1 WHEN 4 THEN 2 ELSE 3 END, doc_count DESC
        \\LIMIT 500
    , .{});
    defer r.deinit();
    while (r.next()) |row| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const stats = Stats{
            .doc_count = row.int(1),
            .len_sum = row.int(2),
            .empty_titles = row.int(3),
            .digit_titles = row.int(4),
            .sample = row.text(5),
        };
        try jw.beginObject();
        try jw.objectField("did");
        try jw.write(row.text(0));
        try jw.objectField("site");
        try jw.write(authorSite(arena.allocator(), row.text(0)) orelse "");
        try jw.objectField("state");
        try jw.write(stateName(row.int(6)));
        try jw.objectField("reason");
        try jw.write(row.text(7));
        try jw.objectField("docs");
        try jw.write(row.int(1));
        try jw.objectField("score");
        try jw.write(stats.score(arena.allocator()));
        // up to 3 normalized title patterns — shows WHY it scored as templated
        try jw.objectField("patterns");
        try jw.beginArray();
        var it = std.mem.splitScalar(u8, stats.sample, '\n');
        var n: usize = 0;
        while (it.next()) |t| {
            if (t.len == 0) continue;
            try jw.write(t);
            n += 1;
            if (n >= 3) break;
        }
        try jw.endArray();
        try jw.endObject();
    }
    try jw.endArray();

    try jw.endObject();
    return out.toOwnedSlice();
}

fn setDecided(conn: zqlite.Conn, did: []const u8, state: i64) void {
    conn.exec("UPDATE author_stats SET labeled = 1, state = ? WHERE did = ?", .{ state, did }) catch {};
}

const Stats = struct {
    doc_count: i64,
    len_sum: i64,
    empty_titles: i64,
    digit_titles: i64,
    sample: []const u8, // newline-joined normalized titles

    fn frac(n: i64, d: i64) f64 {
        return if (d == 0) 0 else @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(d));
    }

    fn clamp01(x: f64) f64 {
        return @max(0.0, @min(1.0, x));
    }

    /// composite 0..1 — same shape as scripts/classify-bulk-mirror.
    fn score(self: Stats, alloc: Allocator) f64 {
        const avg_len = frac(self.len_sum, self.doc_count);
        const thinness = clamp01(1.0 - avg_len / 800.0);
        const structural = @max(frac(self.empty_titles, self.doc_count), frac(self.digit_titles, self.doc_count));
        const dc: f64 = @floatFromInt(self.doc_count);
        const volume = clamp01((std.math.log10(@max(dc, 1.0)) - 2.0) / 2.0);
        const template = self.templateScore(alloc);
        return 0.45 * template + 0.20 * structural + 0.20 * thinness + 0.15 * volume;
    }

    /// Scaffold coverage: how much of each title is shared CONTENT words
    /// (tokens appearing in >=50% of titles). Titles with no content words —
    /// dates, symbols, non-ASCII (Japanese) — contribute 0, NOT 1.0: a human
    /// journal titled by date is not "templated spam". This is the precision
    /// fix; the old `max(1 - distinct-ratio, …)` + `toks==0 -> 1.0` flagged real
    /// people. Empty/date titles are caught by the structural signal instead.
    fn templateScore(self: Stats, alloc: Allocator) f64 {
        var titles: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, self.sample, '\n');
        while (it.next()) |t| {
            if (t.len == 0) continue;
            titles.append(alloc, t) catch return 0;
        }
        const n = titles.items.len;
        if (n == 0) return 0;

        // scaffold: tokens appearing in >= 50% of titles
        var doc_freq = std.StringHashMap(usize).init(alloc);
        for (titles.items) |t| {
            var seen_in_title = std.StringHashMap(void).init(alloc);
            var tit = std.mem.splitScalar(u8, t, ' ');
            while (tit.next()) |w| {
                if (w.len <= 1 or isStopword(w)) continue;
                if (seen_in_title.contains(w)) continue;
                seen_in_title.put(w, {}) catch {};
                const e = doc_freq.getOrPut(w) catch continue;
                e.value_ptr.* = if (e.found_existing) e.value_ptr.* + 1 else 1;
            }
        }
        const half = @as(f64, @floatFromInt(n)) * 0.5;

        var coverage_sum: f64 = 0;
        for (titles.items) |t| {
            var toks: usize = 0;
            var scaffold_toks: usize = 0;
            var tit = std.mem.splitScalar(u8, t, ' ');
            while (tit.next()) |w| {
                if (w.len <= 1 or isStopword(w)) continue;
                toks += 1;
                const f = doc_freq.get(w) orelse 0;
                if (@as(f64, @floatFromInt(f)) >= half) scaffold_toks += 1;
            }
            // no content words (date/symbol/non-ASCII) → NOT templated.
            coverage_sum += if (toks == 0) 0.0 else frac(@intCast(scaffold_toks), @intCast(toks));
        }
        return coverage_sum / @as(f64, @floatFromInt(n));
    }
};

// ── model-pass gate (background review worker) ──────────────────────────────

/// Start the review worker if COCORE_API_KEY is set. Without it, flagged authors
/// stay PENDING (unlabeled) — emission is paused, not faked.
pub fn startReview(allocator: Allocator, io: Io) void {
    const key = if (std.c.getenv("COCORE_API_KEY")) |p| std.mem.span(p) else {
        logfire.info("classifier: model-pass disabled (no COCORE_API_KEY) — flagged authors queue unlabeled", .{});
        return;
    };
    const t = std.Thread.spawn(.{}, reviewWorker, .{ allocator, key, io }) catch |err| {
        logfire.err("classifier: review worker spawn failed: {s}", .{@errorName(err)});
        return;
    };
    t.detach();
    logfire.info("classifier: model-pass review worker started ({s})", .{REVIEW_MODEL});
}

fn reviewWorker(allocator: Allocator, key: []const u8, io: Io) void {
    // authors that exhausted their attempts stay PENDING but invisible to
    // nextPending — without this reset they'd wedge forever. A fresh set of
    // attempts per boot keeps retries bounded (the process restarts on each
    // snapshot adoption) while still never rejecting on provider flakiness.
    var reset_done = false;
    while (true) {
        const conn = g_conn orelse {
            io.sleep(Io.Duration.fromSeconds(30), .awake) catch {};
            continue;
        };
        if (!reset_done) {
            resetExhaustedAttempts(conn);
            reset_done = true;
        }
        const did = nextPending(allocator, conn) orelse {
            io.sleep(Io.Duration.fromSeconds(30), .awake) catch {};
            continue;
        };
        defer allocator.free(did);

        // null verdict = inconclusive (empty/garbled reply, transient provider
        // error, or out of CC) → leave PENDING and retry, never reject. Only a
        // CLEAR machine/human answer decides. The model's reason (free text — the
        // protocol can't carry it on the label, so we keep it ourselves) is
        // stored for the dashboard.
        const verdict: ?Verdict = reviewAuthor(allocator, key, io, did) catch |err| blk: {
            logfire.warn("classifier: review error for {s}: {s} (will retry)", .{ did, @errorName(err) });
            break :blk null;
        };
        if (verdict) |v| {
            defer allocator.free(v.reason);
            const state = if (v.machine) STATE_LABELED else STATE_REJECTED;
            conn.exec("UPDATE author_stats SET state = ?, reason = ? WHERE did = ?", .{ state, v.reason, did }) catch {};
            if (v.machine) {
                _ = labeler.emit(did, labeler.LABEL_MACHINE_GENERATED, false) catch {};
                logfire.info("classifier: model CONFIRMED {s} → machine-generated ({s})", .{ did, v.reason });
                // DRAFT notification — NOT posted yet. We draft to the log (review
                // on /labels first) the heads-up the labeled account would get.
                const site = authorSite(allocator, did);
                defer if (site) |s| allocator.free(s);
                logfire.info("labeler DRAFT notify (NOT posted) → @{s}: pub-search indexes human writing on atproto; this account was classified machine-generated ({s}) and excluded from search. reply to appeal · pub-search.waow.tech/labels", .{ site orelse did, v.reason });
            } else {
                logfire.info("classifier: model REJECTED {s} ({s})", .{ did, v.reason });
            }
        } else {
            // inconclusive → bump attempts; nextPending stops picking it past the
            // cap (abandoned, NOT labeled — precision-first). Slower backoff.
            conn.exec("UPDATE author_stats SET review_attempts = review_attempts + 1 WHERE did = ?", .{did}) catch {};
            logfire.info("classifier: review inconclusive for {s} (will retry)", .{did});
            io.sleep(Io.Duration.fromSeconds(10), .awake) catch {};
            continue;
        }
        io.sleep(Io.Duration.fromSeconds(1), .awake) catch {};
    }
}

fn resetExhaustedAttempts(conn: zqlite.Conn) void {
    conn.exec(
        "UPDATE author_stats SET review_attempts = 0 WHERE state = ? AND review_attempts >= ?",
        .{ STATE_PENDING, MAX_REVIEW_ATTEMPTS },
    ) catch {};
}

fn nextPending(allocator: Allocator, conn: zqlite.Conn) ?[]const u8 {
    const row = (conn.row(
        "SELECT did FROM author_stats WHERE state = ? AND review_attempts < ? ORDER BY review_attempts ASC LIMIT 1",
        .{ STATE_PENDING, MAX_REVIEW_ATTEMPTS },
    ) catch return null) orelse return null;
    defer row.deinit();
    return allocator.dupe(u8, row.text(0)) catch null;
}

const Verdict = struct { machine: bool, reason: []const u8 };

/// Ask the LLM whether the author is a machine-generated mirror, from real
/// sample content. Returns a Verdict (machine + reason), or null = inconclusive
/// (retry). The returned reason is owned by `allocator`.
fn reviewAuthor(allocator: Allocator, key: []const u8, io: Io, did: []const u8) !?Verdict {
    const samples = try fetchSamples(allocator, did);
    defer allocator.free(samples);

    // prompt validated against the known cases on cocore Qwen2.5-7B: the framing
    // (our task: long-form human writing vs automated feeds, "coherent ≠ human")
    // + concrete examples are what make a small model separate a real blog from a
    // transit/catalog feed. Without them it calls everything coherent "human".
    var prompt: std.Io.Writer.Allocating = .init(allocator);
    defer prompt.deinit();
    try prompt.writer.writeAll(
        \\A search engine indexes original long-form writing by people (blogs, essays,
        \\articles). It must EXCLUDE accounts that are automated feeds, catalogs, or
        \\database exports — even when the text reads coherently.
        \\
        \\The test: did a PERSON sit and write each item as original prose, OR is an
        \\automated system emitting one record per database row / feed event / catalog
        \\entry / log?
        \\
        \\machine=true examples: a transit-alert bot ("Red Line delayed near Roosevelt"),
        \\a patent-database mirror, a TV-episode catalog (one entry per episode),
        \\product-recall summaries, daily log entries, chart/stats dumps. Coherent != human.
        \\machine=false examples: a personal blog (tech notes, essays, reviews), even with
        \\branded/templated titles or a numbered series.
        \\
        \\Sample documents from ONE account:
        \\
        \\
    );
    try prompt.writer.writeAll(samples);
    try prompt.writer.writeAll(
        \\
        \\
        \\Respond with ONLY JSON: {"machine": true|false, "reason": "<one sentence>"}
    );

    const reply = try callModel(allocator, key, io, prompt.written());
    defer allocator.free(reply);
    const verdict = parseVerdict(allocator, reply);
    if (verdict == null) {
        // surface WHAT came back — repeated inconclusives are otherwise
        // undiagnosable from the logs (see the sksksketch wedge).
        logfire.warn("classifier: unparseable model reply for {s}: {s}", .{ did, reply[0..@min(reply.len, 300)] });
    }
    return verdict;
}

/// Build a titles+content-excerpt block from the replica (bounded).
fn fetchSamples(allocator: Allocator, did: []const u8) ![]const u8 {
    const local = db.getLocalDbRaw() orelse return error.NoReplica;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var rows = try local.query("SELECT title, content FROM documents WHERE did = ? LIMIT 8", .{did});
    defer rows.deinit();
    var n: usize = 0;
    while (rows.next()) |row| {
        n += 1;
        const title = row.text(0);
        const content = row.text(1);
        const excerpt = utf8Excerpt(content, 400);
        try out.writer.print("- title: {s}\n  content: {s}\n\n", .{ title, excerpt });
    }
    if (n == 0) return error.NoSamples;
    return out.toOwnedSlice();
}

/// Bounded prefix trimmed to a UTF-8 codepoint boundary — a mid-codepoint
/// slice puts invalid UTF-8 in the JSON payload and the model reply comes
/// back garbled (this kept CJK-content authors permanently "inconclusive").
fn utf8Excerpt(s: []const u8, max: usize) []const u8 {
    var end = @min(s.len, max);
    while (end > 0 and end < s.len and s[end] & 0xC0 == 0x80) end -= 1;
    return s[0..end];
}

/// co/core is OpenAI-compatible: POST /chat/completions, Bearer auth.
fn callModel(allocator: Allocator, key: []const u8, io: Io, prompt: []const u8) ![]const u8 {
    var client: http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    var jw: json.Stringify = .{ .writer = &body.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("model");
    try jw.write(REVIEW_MODEL);
    try jw.objectField("max_tokens");
    try jw.write(150);
    try jw.objectField("temperature");
    try jw.write(0);
    try jw.objectField("messages");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write("user");
    try jw.objectField("content");
    try jw.write(prompt);
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();
    const payload = try body.toOwnedSlice();
    defer allocator.free(payload);

    var auth_buf: [256]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{key}) catch return error.AuthTooLong;

    var resp: std.Io.Writer.Allocating = .init(allocator);
    errdefer resp.deinit();
    const res = client.fetch(.{
        .location = .{ .url = COCORE_URL },
        .method = .POST,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = auth },
        },
        .payload = payload,
        .response_writer = &resp.writer,
    }) catch return error.CocoreRequestFailed;

    const text = try resp.toOwnedSlice();
    if (res.status != .ok) {
        defer allocator.free(text);
        logfire.err("classifier: cocore {}: {s}", .{ res.status, text[0..@min(text.len, 200)] });
        return error.CocoreApiError;
    }
    return text;
}

/// Pull the verdict + reason out of the OpenAI envelope. The content is
/// {"machine": bool, "reason": "..."}. Returns null when the reply is
/// empty/garbled/missing (transient failure or out of CC) so the worker retries
/// instead of falsely rejecting. The reason is owned by `allocator`.
fn parseVerdict(allocator: Allocator, response: []const u8) ?Verdict {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = json.parseFromSliceLeaky(json.Value, a, response, .{}) catch return null;
    if (parsed != .object) return null;
    const choices = parsed.object.get("choices") orelse return null;
    if (choices != .array or choices.array.items.len == 0) return null;
    const msg = choices.array.items[0].object.get("message") orelse return null;
    const content = msg.object.get("content") orelse return null;
    if (content != .string or content.string.len == 0) return null;
    const s = content.string;

    // machine verdict — tolerate prose; a small model may not return pure JSON.
    const machine: bool = blk: {
        if (std.mem.indexOf(u8, s, "\"machine\": true") != null or std.mem.indexOf(u8, s, "\"machine\":true") != null) break :blk true;
        if (std.mem.indexOf(u8, s, "\"machine\": false") != null or std.mem.indexOf(u8, s, "\"machine\":false") != null) break :blk false;
        return null; // unexpected shape → retry
    };

    // reason — prefer the JSON field; else the trimmed content. Best-effort.
    var reason: []const u8 = "";
    if (json.parseFromSliceLeaky(json.Value, a, s, .{})) |inner| {
        if (inner == .object) {
            if (inner.object.get("reason")) |rv| {
                if (rv == .string) reason = rv.string;
            }
        }
    } else |_| {}
    const capped = reason[0..@min(reason.len, 280)];
    return .{ .machine = machine, .reason = allocator.dupe(u8, capped) catch "" };
}

/// True if anyone recommends a doc by this author, or subscribes to one of
/// their publications. Read from the frozen local replica (indexed existence
/// checks; rare — only on a threshold crossing).
fn hasCuration(did: []const u8) bool {
    const local = db.getLocalDbRaw() orelse return false;
    if (!local.isReady()) return false;
    var rows = local.query(
        \\SELECT EXISTS(SELECT 1 FROM recommends r JOIN documents d ON r.document_uri = d.uri WHERE d.did = ?)
        \\    OR EXISTS(SELECT 1 FROM subscriptions s JOIN publications p ON s.publication_uri = p.uri WHERE p.did = ?)
    , .{ did, did }) catch return false;
    defer rows.deinit();
    if (rows.next()) |row| return row.int(0) != 0;
    return false;
}

fn hasDigit(s: []const u8) bool {
    for (s) |c| if (std.ascii.isDigit(c)) return true;
    return false;
}

/// lowercase, digit-runs → '#', non-alnum → space, collapse whitespace.
fn normalizeTitle(title: []const u8, buf: *[256]u8) []const u8 {
    var w: usize = 0;
    var last_space = true; // strip leading
    var i: usize = 0;
    while (i < title.len and w < buf.len) {
        const c = title[i];
        if (std.ascii.isDigit(c)) {
            if (w < buf.len) {
                buf[w] = '#';
                w += 1;
            }
            while (i < title.len and std.ascii.isDigit(title[i])) i += 1; // collapse digit run
            last_space = false;
            continue;
        }
        if (std.ascii.isAlphabetic(c)) {
            buf[w] = std.ascii.toLower(c);
            w += 1;
            last_space = false;
        } else {
            if (!last_space and w < buf.len) {
                buf[w] = ' ';
                w += 1;
                last_space = true;
            }
        }
        i += 1;
    }
    var out = buf[0..w];
    if (out.len > 0 and out[out.len - 1] == ' ') out = out[0 .. out.len - 1];
    return out;
}

// === tests ===

test "normalizeTitle collapses digits + punctuation" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("train # stopped", normalizeTitle("Train 807 Stopped", &buf));
    try std.testing.expectEqualStrings("i felt rad", normalizeTitle("I felt rad!", &buf));
    try std.testing.expectEqualStrings("s#e# the cadillac", normalizeTitle("S07E14: The Cadillac", &buf));
}

test "templateScore: templated high, diverse low" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // transit-alert style: shared scaffold "line/delays/route/detour"
    const templated = Stats{
        .doc_count = 6,
        .len_sum = 600,
        .empty_titles = 0,
        .digit_titles = 0,
        .sample = "green line delays\nblue line delays\nred line delays\nroute # detour\nroute # detour\ngold line delays",
    };
    // diverse human titles
    const diverse = Stats{
        .doc_count = 5,
        .len_sum = 4000,
        .empty_titles = 0,
        .digit_titles = 0,
        .sample = "new sleigh bells album\nthe dreaming void\nwe lost the thread\nsimple data fetching\ndangerous animals",
    };
    try std.testing.expect(diverse.templateScore(a) < 0.3);
    // templated scaffolding scores well above diverse human titles
    try std.testing.expect(templated.templateScore(a) > 0.4);
    try std.testing.expect(templated.templateScore(a) > diverse.templateScore(a) + 0.2);
}

test "score: flagged vs kept separation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const transit = Stats{
        .doc_count = 555,
        .len_sum = 555 * 183,
        .empty_titles = 0,
        .digit_titles = 400,
        .sample = "train # stopped\ntrain # delayed\nline service delayed\ntrain # annulled\nline delay\ntrain # delayed",
    };
    try std.testing.expect(transit.score(a) >= THRESHOLD);

    // real human, even with short content (mikebifulco-like): diverse titles save it
    const human = Stats{
        .doc_count = 203,
        .len_sum = 203 * 143,
        .empty_titles = 0,
        .digit_titles = 5,
        .sample = "struggling with typescript\nbreaking the cycle\ntiny improvements\nwhat to do when\nserendipity isnt\nopen source your work",
    };
    try std.testing.expect(human.score(a) < THRESHOLD);
}

test "parseVerdict: clear verdicts decide + carry reason, empty/garbled retries" {
    const a = std.testing.allocator;
    const machine = "{\"choices\":[{\"message\":{\"content\":\"{\\\"machine\\\": true, \\\"reason\\\":\\\"automated feed\\\"}\"}}]}";
    const human = "{\"choices\":[{\"message\":{\"content\":\"{\\\"machine\\\": false, \\\"reason\\\":\\\"personal blog\\\"}\"}}]}";

    const m = parseVerdict(a, machine).?;
    defer a.free(m.reason);
    try std.testing.expect(m.machine);
    try std.testing.expectEqualStrings("automated feed", m.reason);

    const h = parseVerdict(a, human).?;
    defer a.free(h.reason);
    try std.testing.expect(!h.machine);
    try std.testing.expectEqualStrings("personal blog", h.reason);

    try std.testing.expect(parseVerdict(a, "{\"choices\":[{\"message\":{\"content\":\"\"}}]}") == null); // → retry
    try std.testing.expect(parseVerdict(a, "not json") == null); // → retry
    try std.testing.expect(parseVerdict(a, "{\"choices\":[]}") == null); // → retry
}

test "date-titled journal is NOT flagged (precision regression: firstwaterbottle)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // observe() stores normalized titles; "1/27/2026" → "# # #" (no content words).
    const journal = Stats{
        .doc_count = 98,
        .len_sum = 98 * 400,
        .empty_titles = 0,
        .digit_titles = 98, // every title has digits
        .sample = "# # #\n# # #\n# # #\n# # #\n# # #\n# # #",
    };
    // the old code scored this maximally templated (1.0) → false positive.
    try std.testing.expectEqual(@as(f64, 0), journal.templateScore(a));
    try std.testing.expect(journal.score(a) < THRESHOLD);
}

test "utf8Excerpt never splits a codepoint (regression: CJK authors stuck inconclusive)" {
    // "스케치" is 9 bytes (3 per codepoint); cutting at 4/5 must fall back to 3.
    const kr = "스케치";
    try std.testing.expectEqualStrings("스", utf8Excerpt(kr, 4));
    try std.testing.expectEqualStrings("스", utf8Excerpt(kr, 5));
    try std.testing.expectEqualStrings("스케", utf8Excerpt(kr, 6));
    try std.testing.expectEqualStrings(kr, utf8Excerpt(kr, 100)); // shorter than max: untouched
    try std.testing.expectEqualStrings("abc", utf8Excerpt("abcdef", 3)); // ascii: plain cut
    try std.testing.expect(std.unicode.utf8ValidateSlice(utf8Excerpt(kr, 4)));
}

test "exhausted pending authors get fresh attempts on worker start (regression: sksksketch wedge)" {
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite);
    defer conn.close();
    try conn.execNoArgs("CREATE TABLE author_stats (did TEXT PRIMARY KEY, state INTEGER NOT NULL, review_attempts INTEGER NOT NULL)");
    try conn.exec("INSERT INTO author_stats VALUES ('did:stuck', ?, ?)", .{ STATE_PENDING, MAX_REVIEW_ATTEMPTS });
    try conn.exec("INSERT INTO author_stats VALUES ('did:fresh', ?, 2)", .{STATE_PENDING});
    try conn.exec("INSERT INTO author_stats VALUES ('did:done', ?, ?)", .{ STATE_LABELED, MAX_REVIEW_ATTEMPTS });

    resetExhaustedAttempts(conn);

    const attempts = struct {
        fn of(c: zqlite.Conn, did: []const u8) !i64 {
            const row = (try c.row("SELECT review_attempts FROM author_stats WHERE did = ?", .{did})).?;
            defer row.deinit();
            return row.int(0);
        }
    };
    try std.testing.expectEqual(@as(i64, 0), try attempts.of(conn, "did:stuck")); // visible to nextPending again
    try std.testing.expectEqual(@as(i64, 2), try attempts.of(conn, "did:fresh")); // in-flight count untouched
    try std.testing.expectEqual(MAX_REVIEW_ATTEMPTS, try attempts.of(conn, "did:done")); // non-pending untouched
}
