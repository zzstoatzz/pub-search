//! Autonomous bulk-mirror classifier — the labeler's brain.
//!
//! The labeler watches the firehose and labels on its own: every ingested
//! document is fed here via observe(), which keeps a rolling per-DID aggregate
//! in its OWN SQLite (never turso, never the frozen replica, never blocks the
//! firehose). When a DID crosses a volume floor it is scored in-process; if it
//! looks like a machine-generated registry/feed mirror, the labeler emits a
//! signed `bulk-mirror` account label — no human in the loop.
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
// scaffold only, curation veto). v3 = threshold 0.55→0.50.
const SCORING_VERSION: i64 = 3;
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
        for (prev.items) |did| _ = labeler.emit(did, labeler.LABEL_BULK_MIRROR, true) catch {};
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

    // curation veto: if anyone recommends or subscribes to this author, never
    // label them — that's a human-curation signal a mirror won't have. Mark
    // decided so we stop re-scoring.
    if (hasCuration(did)) {
        conn.exec("UPDATE author_stats SET labeled = 1 WHERE did = ?", .{did}) catch {};
        logfire.info("classifier: vetoed {s} (score={d:.3} but has curation)", .{ did, score });
        return;
    }

    // emit the label (the labeler signs/stores/broadcasts), then mark decided so
    // we never emit twice. If the labeler isn't configured, leave unlabeled so a
    // later boot with a key can still emit.
    _ = labeler.emit(did, labeler.LABEL_BULK_MIRROR, false) catch |err| {
        if (err != error.NotConfigured)
            logfire.err("classifier: emit failed for {s}: {s}", .{ did, @errorName(err) });
        return;
    };
    conn.exec("UPDATE author_stats SET labeled = 1 WHERE did = ?", .{did}) catch {};
    logfire.info("classifier: auto-labeled {s} bulk-mirror (score={d:.3} docs={d})", .{ did, score, doc_count });
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
