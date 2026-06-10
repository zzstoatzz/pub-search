const std = @import("std");
const db = @import("../db.zig");
const activity = @import("activity.zig");
const stats_buffer = @import("buffer.zig");

pub const Stats = struct {
    documents: i64,
    publications: i64,
    embeddings: i64,
    searches: i64,
    errors: i64,
    started_at: i64,
    cache_hits: i64,
    cache_misses: i64,
};

const default_stats: Stats = .{ .documents = 0, .publications = 0, .embeddings = 0, .searches = 0, .errors = 0, .started_at = 0, .cache_hits = 0, .cache_misses = 0 };

// last successful local read. /stats backs the public page footer — a few
// seconds of staleness is invisible, but a live turso query on the request
// path can stall for seconds under write pressure (1/60 soak probes,
// 2026-06-10). plain struct copy guarded by the write being rare and the
// fields being independently-read counters: a torn read across fields is
// harmless here.
var last_good: ?Stats = null;

pub fn getStats() Stats {
    // try local SQLite first (fast)
    if (db.getLocalDb()) |local| {
        if (getStatsLocal(local)) |result| {
            last_good = result;
            return result;
        } else |_| {}
    }

    // serve slightly-stale counts rather than block on a live turso query
    if (last_good) |cached| return cached;

    // first-ever read (boot, local not ready yet): turso is the only source
    const c = db.getClient() orelse return default_stats;

    var res = c.query(
        \\SELECT
        \\  (SELECT COUNT(*) FROM documents) as docs,
        \\  (SELECT COUNT(*) FROM publications) as pubs,
        \\  (SELECT COUNT(*) FROM documents WHERE embedded_at IS NOT NULL) as embeddings,
        \\  (SELECT total_searches FROM stats WHERE id = 1) as searches,
        \\  (SELECT total_errors FROM stats WHERE id = 1) as errors,
        \\  (SELECT service_started_at FROM stats WHERE id = 1) as started_at,
        \\  (SELECT COALESCE(cache_hits, 0) FROM stats WHERE id = 1) as cache_hits,
        \\  (SELECT COALESCE(cache_misses, 0) FROM stats WHERE id = 1) as cache_misses
    , &.{}) catch return default_stats;
    defer res.deinit();

    const row = res.first() orelse return default_stats;
    // include pending deltas from buffer
    return .{
        .documents = row.int(0),
        .publications = row.int(1),
        .embeddings = row.int(2),
        .searches = stats_buffer.getSearchCount(row.int(3)),
        .errors = stats_buffer.getErrorCount(row.int(4)),
        .started_at = row.int(5),
        .cache_hits = stats_buffer.getCacheHitCount(row.int(6)),
        .cache_misses = stats_buffer.getCacheMissCount(row.int(7)),
    };
}

fn getStatsLocal(local: *db.LocalDb) !Stats {
    // get document counts from local (fast)
    var rows = try local.query(
        \\SELECT
        \\  (SELECT COUNT(*) FROM documents) as docs,
        \\  (SELECT COUNT(*) FROM publications) as pubs,
        \\  (SELECT COUNT(*) FROM documents WHERE embedded_at IS NOT NULL) as embeddings
    , .{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRows;

    // use cached stats from stats_buffer if available (searches, errors, etc.)
    const cached = stats_buffer.getCachedStats();
    return .{
        .documents = row.int(0),
        .publications = row.int(1),
        .embeddings = row.int(2),
        .searches = if (cached) |c| c.searches else 0,
        .errors = if (cached) |c| c.errors else 0,
        .started_at = if (cached) |c| c.started_at else 0,
        .cache_hits = if (cached) |c| c.cache_hits else 0,
        .cache_misses = if (cached) |c| c.cache_misses else 0,
    };
}

pub fn recordSearch(query: []const u8) void {
    activity.record();
    stats_buffer.recordSearch();
    stats_buffer.queuePopularSearch(query);
}

pub fn recordError() void {
    stats_buffer.recordError();
}

pub fn recordCacheHit() void {
    stats_buffer.recordCacheHit();
}

pub fn recordCacheMiss() void {
    stats_buffer.recordCacheMiss();
}
