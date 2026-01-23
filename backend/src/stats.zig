const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const zql = @import("zql");
const db = @import("db/mod.zig");
const activity = @import("activity.zig");

const TagJson = struct { tag: []const u8, count: i64 };
const PopularJson = struct { query: []const u8, count: i64 };

const TagsQuery = zql.Query(
    \\SELECT tag, COUNT(*) as count
    \\FROM document_tags
    \\GROUP BY tag
    \\ORDER BY count DESC
    \\LIMIT 100
);

pub fn getTags(alloc: Allocator) ![]const u8 {
    // try local SQLite first (faster)
    if (db.getLocalDb()) |local| {
        if (getTagsLocal(alloc, local)) |result| {
            return result;
        } else |_| {}
    }

    // fall back to Turso
    const c = db.getClient() orelse return error.NotInitialized;

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var res = c.query(TagsQuery.positional, &.{}) catch {
        try output.writer.writeAll("{\"error\":\"failed to fetch tags\"}");
        return try output.toOwnedSlice();
    };
    defer res.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (res.rows) |row| try jw.write(TagJson{ .tag = row.text(0), .count = row.int(1) });
    try jw.endArray();
    return try output.toOwnedSlice();
}

fn getTagsLocal(alloc: Allocator, local: *db.LocalDb) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var rows = try local.query(
        \\SELECT tag, COUNT(*) as count
        \\FROM document_tags
        \\GROUP BY tag
        \\ORDER BY count DESC
        \\LIMIT 100
    , .{});
    defer rows.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    while (rows.next()) |row| {
        try jw.write(TagJson{ .tag = row.text(0), .count = row.int(1) });
    }
    try jw.endArray();
    return try output.toOwnedSlice();
}

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

pub fn getStats() Stats {
    // try local SQLite first (fast)
    if (db.getLocalDb()) |local| {
        if (getStatsLocal(local)) |result| {
            return result;
        } else |_| {}
    }

    // fall back to Turso (slow)
    const c = db.getClient() orelse return default_stats;

    var res = c.query(
        \\SELECT
        \\  (SELECT COUNT(*) FROM documents) as docs,
        \\  (SELECT COUNT(*) FROM publications) as pubs,
        \\  (SELECT COUNT(*) FROM documents WHERE embedding IS NOT NULL) as embeddings,
        \\  (SELECT total_searches FROM stats WHERE id = 1) as searches,
        \\  (SELECT total_errors FROM stats WHERE id = 1) as errors,
        \\  (SELECT service_started_at FROM stats WHERE id = 1) as started_at,
        \\  (SELECT COALESCE(cache_hits, 0) FROM stats WHERE id = 1) as cache_hits,
        \\  (SELECT COALESCE(cache_misses, 0) FROM stats WHERE id = 1) as cache_misses
    , &.{}) catch return default_stats;
    defer res.deinit();

    const row = res.first() orelse return default_stats;
    return .{
        .documents = row.int(0),
        .publications = row.int(1),
        .embeddings = row.int(2),
        .searches = row.int(3),
        .errors = row.int(4),
        .started_at = row.int(5),
        .cache_hits = row.int(6),
        .cache_misses = row.int(7),
    };
}

fn getStatsLocal(local: *db.LocalDb) !Stats {
    // get stats table from Turso (doesn't sync to local replica)
    const client = db.getClient() orelse return error.NotInitialized;
    var stats_res = client.query(
        \\SELECT total_searches, total_errors, service_started_at,
        \\       COALESCE(cache_hits, 0), COALESCE(cache_misses, 0)
        \\FROM stats WHERE id = 1
    , &.{}) catch return error.QueryFailed;
    defer stats_res.deinit();
    const stats_row = stats_res.first() orelse return error.NoStats;

    // get document counts from local (fast)
    var rows = try local.query(
        \\SELECT
        \\  (SELECT COUNT(*) FROM documents) as docs,
        \\  (SELECT COUNT(*) FROM publications) as pubs,
        \\  (SELECT COUNT(*) FROM documents WHERE embedding IS NOT NULL) as embeddings
    , .{});
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRows;

    return .{
        .documents = row.int(0),
        .publications = row.int(1),
        .embeddings = row.int(2),
        .searches = stats_row.int(0),
        .errors = stats_row.int(1),
        .started_at = stats_row.int(2),
        .cache_hits = stats_row.int(3),
        .cache_misses = stats_row.int(4),
    };
}

pub fn recordSearch(query: []const u8) void {
    const c = db.getClient() orelse return;

    activity.record();
    c.exec("UPDATE stats SET total_searches = total_searches + 1 WHERE id = 1", &.{}) catch {};

    // track popular searches (skip empty/very short queries)
    if (query.len >= 2) {
        c.exec(
            "INSERT INTO popular_searches (query, count) VALUES (?, 1) ON CONFLICT(query) DO UPDATE SET count = count + 1",
            &.{query},
        ) catch {};
    }
}

pub fn recordError() void {
    const c = db.getClient() orelse return;
    c.exec("UPDATE stats SET total_errors = total_errors + 1 WHERE id = 1", &.{}) catch {};
}

pub fn recordCacheHit() void {
    const c = db.getClient() orelse return;
    c.exec("UPDATE stats SET cache_hits = COALESCE(cache_hits, 0) + 1 WHERE id = 1", &.{}) catch {};
}

pub fn recordCacheMiss() void {
    const c = db.getClient() orelse return;
    c.exec("UPDATE stats SET cache_misses = COALESCE(cache_misses, 0) + 1 WHERE id = 1", &.{}) catch {};
}

const PlatformCount = struct { platform: []const u8, count: i64 };

pub fn getPlatformCounts(alloc: Allocator) ![]const u8 {
    const c = db.getClient() orelse return error.NotInitialized;

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginObject();

    // documents by platform
    try jw.objectField("documents");
    if (c.query("SELECT platform, COUNT(*) as count FROM documents GROUP BY platform ORDER BY count DESC", &.{})) |res_val| {
        var res = res_val;
        defer res.deinit();
        try jw.beginArray();
        for (res.rows) |row| try jw.write(PlatformCount{ .platform = row.text(0), .count = row.int(1) });
        try jw.endArray();
    } else |_| {
        try jw.beginArray();
        try jw.endArray();
    }

    // FTS document count
    try jw.objectField("fts_count");
    if (c.query("SELECT COUNT(*) FROM documents_fts", &.{})) |res_val| {
        var res = res_val;
        defer res.deinit();
        if (res.first()) |row| {
            try jw.write(row.int(0));
        } else try jw.write(0);
    } else |_| try jw.write(0);

    // sample URIs from each platform (for debugging)
    try jw.objectField("sample_other");
    if (c.query("SELECT uri FROM documents WHERE platform = 'other' LIMIT 3", &.{})) |res_val| {
        var res = res_val;
        defer res.deinit();
        try jw.beginArray();
        for (res.rows) |row| try jw.write(row.text(0));
        try jw.endArray();
    } else |_| {
        try jw.beginArray();
        try jw.endArray();
    }

    try jw.endObject();
    return try output.toOwnedSlice();
}

pub fn getPopular(alloc: Allocator, limit: usize) ![]const u8 {
    // try local SQLite first (faster)
    if (db.getLocalDb()) |local| {
        if (getPopularLocal(alloc, local, limit)) |result| {
            return result;
        } else |_| {}
    }

    // fall back to Turso
    const c = db.getClient() orelse return error.NotInitialized;

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var buf: [8]u8 = undefined;
    const limit_str = std.fmt.bufPrint(&buf, "{d}", .{limit}) catch "3";

    var res = c.query(
        "SELECT query, count FROM popular_searches ORDER BY count DESC LIMIT ?",
        &.{limit_str},
    ) catch {
        try output.writer.writeAll("[]");
        return try output.toOwnedSlice();
    };
    defer res.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (res.rows) |row| try jw.write(PopularJson{ .query = row.text(0), .count = row.int(1) });
    try jw.endArray();
    return try output.toOwnedSlice();
}

fn getPopularLocal(alloc: Allocator, local: *db.LocalDb, limit: usize) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    _ = limit; // zqlite doesn't support runtime LIMIT, use fixed 10
    var rows = try local.query(
        "SELECT query, count FROM popular_searches ORDER BY count DESC LIMIT 10",
        .{},
    );
    defer rows.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    while (rows.next()) |row| {
        try jw.write(PopularJson{ .query = row.text(0), .count = row.int(1) });
    }
    try jw.endArray();
    return try output.toOwnedSlice();
}
