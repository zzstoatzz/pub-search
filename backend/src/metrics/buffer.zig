//! Buffered stats with background sync to Turso
//! Follows activity.zig pattern: instant local writes, periodic remote sync

const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");
const logfire = @import("logfire");

const SYNC_INTERVAL_MS = 5000; // 5 seconds
const MAX_PENDING_SEARCHES = 256;

// atomic deltas (since last sync)
var delta_searches: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);
var delta_errors: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);
var delta_cache_hits: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);
var delta_cache_misses: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

// cached base values from Turso (refreshed every sync cycle)
var cached_base_searches: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);
var cached_base_errors: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);
var cached_base_cache_hits: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);
var cached_base_cache_misses: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);
var cached_started_at: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);
var cache_initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// popular searches ring buffer
var pending_searches: [MAX_PENDING_SEARCHES]?[]const u8 = .{null} ** MAX_PENDING_SEARCHES;
var search_write_idx: usize = 0;
var search_read_idx: usize = 0;
var search_mutex: Io.Mutex = Io.Mutex.init;
var global_io: ?Io = null;

// allocator for search string copies
const search_allocator = std.heap.smp_allocator;

var sync_thread: ?std.Thread = null;

pub fn init(io: Io) void {
    global_io = io;

    // seed cache immediately (so first /stats request is fast)
    if (db.getClient()) |c| {
        refreshCachedStats(c);
        logfire.debug("stats_buffer: seeded cache from Turso", .{});
    }

    sync_thread = std.Thread.spawn(.{}, syncLoop, .{}) catch |err| {
        logfire.warn("stats_buffer: failed to start sync thread: {}", .{err});
        return;
    };
    if (sync_thread) |t| t.detach();
    logfire.info("stats_buffer: initialized with {d}ms sync interval", .{SYNC_INTERVAL_MS});
}

// instant, non-blocking increments
pub fn recordSearch() void {
    _ = delta_searches.fetchAdd(1, .monotonic);
}

pub fn recordError() void {
    _ = delta_errors.fetchAdd(1, .monotonic);
}

pub fn recordCacheHit() void {
    _ = delta_cache_hits.fetchAdd(1, .monotonic);
}

pub fn recordCacheMiss() void {
    _ = delta_cache_misses.fetchAdd(1, .monotonic);
}

// Normalize a query for the popular log: trim whitespace, lowercase.
// Merges "Python" / "python" / " python " into one row so the popularity
// distribution isn't fragmented by trivial input variation. Returns an
// owned slice (caller frees) or null if the normalized result is too short
// to be meaningful.
fn normalizeQuery(alloc: std.mem.Allocator, query: []const u8) ?[]u8 {
    const trimmed = std.mem.trim(u8, query, &std.ascii.whitespace);
    if (trimmed.len < 2) return null;
    const lower = alloc.alloc(u8, trimmed.len) catch return null;
    for (trimmed, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    return lower;
}

// queue popular search (best effort, drops if full)
pub fn queuePopularSearch(query: []const u8) void {
    const io = global_io.?;
    const normalized = normalizeQuery(search_allocator, query) orelse return;

    search_mutex.lockUncancelable(io);
    defer search_mutex.unlock(io);

    // check if buffer is full
    const next_write = (search_write_idx + 1) % MAX_PENDING_SEARCHES;
    if (next_write == search_read_idx) {
        // buffer full, drop oldest
        if (pending_searches[search_read_idx]) |old| {
            search_allocator.free(old);
            pending_searches[search_read_idx] = null;
        }
        search_read_idx = (search_read_idx + 1) % MAX_PENDING_SEARCHES;
    }

    pending_searches[search_write_idx] = normalized;
    search_write_idx = next_write;
}

// get current totals (base from db + pending deltas)
pub fn getSearchCount(base: i64) i64 {
    return base + delta_searches.load(.acquire);
}

pub fn getErrorCount(base: i64) i64 {
    return base + delta_errors.load(.acquire);
}

pub fn getCacheHitCount(base: i64) i64 {
    return base + delta_cache_hits.load(.acquire);
}

pub fn getCacheMissCount(base: i64) i64 {
    return base + delta_cache_misses.load(.acquire);
}

// cached stats (base + delta) - returns null if cache not yet initialized
pub const CachedStats = struct {
    searches: i64,
    errors: i64,
    cache_hits: i64,
    cache_misses: i64,
    started_at: i64,
};

pub fn getCachedStats() ?CachedStats {
    if (!cache_initialized.load(.acquire)) return null;
    return .{
        .searches = cached_base_searches.load(.acquire) + delta_searches.load(.acquire),
        .errors = cached_base_errors.load(.acquire) + delta_errors.load(.acquire),
        .cache_hits = cached_base_cache_hits.load(.acquire) + delta_cache_hits.load(.acquire),
        .cache_misses = cached_base_cache_misses.load(.acquire) + delta_cache_misses.load(.acquire),
        .started_at = cached_started_at.load(.acquire),
    };
}

fn syncLoop() void {
    const io = global_io.?;
    while (true) {
        io.sleep(Io.Duration.fromMilliseconds(SYNC_INTERVAL_MS), .awake) catch {};
        syncToTurso();
    }
}

fn syncToTurso() void {
    const c = db.getClient() orelse return;

    // swap deltas to zero and get values
    const searches = delta_searches.swap(0, .acq_rel);
    const errors = delta_errors.swap(0, .acq_rel);
    const cache_hits = delta_cache_hits.swap(0, .acq_rel);
    const cache_misses = delta_cache_misses.swap(0, .acq_rel);

    // sync stats if any changed
    if (searches != 0 or errors != 0 or cache_hits != 0 or cache_misses != 0) {
        syncStatsDelta(c, searches, errors, cache_hits, cache_misses);
    }

    // always refresh cache (recovers from init failure, picks up external changes)
    refreshCachedStats(c);

    // sync popular searches
    syncPopularSearches(c);
}

fn refreshCachedStats(c: *db.Client) void {
    var res = c.query(
        \\SELECT total_searches, total_errors, service_started_at,
        \\       COALESCE(cache_hits, 0), COALESCE(cache_misses, 0)
        \\FROM stats WHERE id = 1
    , &.{}) catch |err| {
        logfire.warn("stats_buffer: refresh query failed: {}", .{err});
        return;
    };
    defer res.deinit();

    const row = res.first() orelse {
        logfire.warn("stats_buffer: stats table has no row with id=1", .{});
        return;
    };
    const searches = row.int(0);
    const errors = row.int(1);
    const started = row.int(2);
    cached_base_searches.store(searches, .release);
    cached_base_errors.store(errors, .release);
    cached_started_at.store(started, .release);
    cached_base_cache_hits.store(row.int(3), .release);
    cached_base_cache_misses.store(row.int(4), .release);

    if (!cache_initialized.load(.acquire)) {
        logfire.info("stats_buffer: cache initialized (searches={d}, started_at={d})", .{ searches, started });
    }
    cache_initialized.store(true, .release);
}

fn syncStatsDelta(c: *db.Client, searches: i64, errors: i64, cache_hits: i64, cache_misses: i64) void {
    // build SQL with values embedded (safe - these are i64, not user input)
    var sql_buf: [512]u8 = undefined;
    const sql = std.fmt.bufPrint(&sql_buf,
        \\UPDATE stats SET
        \\  total_searches = total_searches + {d},
        \\  total_errors = total_errors + {d},
        \\  cache_hits = COALESCE(cache_hits, 0) + {d},
        \\  cache_misses = COALESCE(cache_misses, 0) + {d}
        \\WHERE id = 1
    , .{ searches, errors, cache_hits, cache_misses }) catch return;

    // use queryBatch which accepts runtime SQL
    var statements = [_]db.Client.Statement{.{ .sql = sql, .args = &.{} }};
    var batch = c.queryBatch(&statements) catch |err| {
        logfire.warn("stats_buffer: sync failed: {}, restoring deltas", .{err});
        // restore deltas on failure
        _ = delta_searches.fetchAdd(searches, .monotonic);
        _ = delta_errors.fetchAdd(errors, .monotonic);
        _ = delta_cache_hits.fetchAdd(cache_hits, .monotonic);
        _ = delta_cache_misses.fetchAdd(cache_misses, .monotonic);
        return;
    };
    batch.deinit();

    logfire.debug("stats_buffer: synced deltas (searches={d}, errors={d}, hits={d}, misses={d})", .{ searches, errors, cache_hits, cache_misses });
}

fn syncPopularSearches(c: *db.Client) void {
    const io = global_io.?;
    search_mutex.lockUncancelable(io);
    defer search_mutex.unlock(io);

    var synced: usize = 0;
    while (search_read_idx != search_write_idx) {
        if (pending_searches[search_read_idx]) |query| {
            // Append an event row instead of bumping a monotonic counter — lets
            // /popular window by recency and lets old test/seed traffic age out.
            // Timestamps are stamped at sync time (not queue time), so events
            // in the same batch share a second-level timestamp. Acceptable
            // because the sync interval is small (~5s).
            c.exec(
                "INSERT INTO search_events (query, at) VALUES (?, strftime('%s', 'now'))",
                &.{query},
            ) catch {};

            // free and clear
            search_allocator.free(query);
            pending_searches[search_read_idx] = null;
            synced += 1;
        }
        search_read_idx = (search_read_idx + 1) % MAX_PENDING_SEARCHES;
    }

    if (synced > 0) {
        logfire.debug("stats_buffer: synced {d} search events", .{synced});
    }
}
