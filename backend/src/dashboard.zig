const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const db = @import("db/mod.zig");
const logfire = @import("logfire");
const timing = @import("metrics.zig").timing;

// JSON output types
const TagJson = struct { tag: []const u8, count: i64 };
const TimelineJson = struct { date: []const u8, count: i64 };
const PubJson = struct { name: []const u8, basePath: []const u8, count: i64 };
const PlatformJson = struct { platform: []const u8, count: i64 };

/// All data needed to render the dashboard
pub const Data = struct {
    started_at: i64,
    searches: i64,
    publications: i64,
    documents: i64,
    embeddings: i64,
    tags_json: []const u8,
    timeline_json: []const u8,
    top_pubs_json: []const u8,
    platforms_json: []const u8,
    timing_json: []const u8,
};

// all dashboard queries batched into one request
const STATS_SQL =
    \\SELECT
    \\  (SELECT COUNT(*) FROM documents) as docs,
    \\  (SELECT COUNT(*) FROM publications) as pubs,
    \\  (SELECT total_searches FROM stats WHERE id = 1) as searches,
    \\  (SELECT total_errors FROM stats WHERE id = 1) as errors,
    \\  (SELECT service_started_at FROM stats WHERE id = 1) as started_at,
    \\  (SELECT COUNT(*) FROM documents WHERE embedded_at IS NOT NULL) as embeddings
;

const PLATFORMS_SQL =
    \\SELECT platform, COUNT(*) as count
    \\FROM documents
    \\GROUP BY platform
    \\ORDER BY count DESC
;

pub const TAGS_SQL =
    \\SELECT tag, COUNT(*) as count
    \\FROM document_tags
    \\GROUP BY tag
    \\ORDER BY count DESC
    \\LIMIT 100
;

const TIMELINE_SQL =
    \\SELECT DATE(created_at) as date, COUNT(*) as count
    \\FROM documents
    \\WHERE created_at IS NOT NULL AND created_at != ''
    \\GROUP BY DATE(created_at)
    \\ORDER BY date DESC
    \\LIMIT 30
;

const TOP_PUBS_SQL =
    \\SELECT p.name, p.base_path, COUNT(d.uri) as doc_count
    \\FROM publications p
    \\JOIN documents d ON d.publication_uri = p.uri
    \\GROUP BY p.uri
    \\ORDER BY doc_count DESC
    \\LIMIT 8
;

pub fn fetch(alloc: Allocator) !Data {
    // try local SQLite first (fast)
    if (db.getLocalDb()) |local| {
        if (fetchLocal(alloc, local)) |result| {
            return result;
        } else |err| {
            logfire.warn("dashboard: fetchLocal failed: {s}, falling back to turso batch", .{@errorName(err)});
        }
    }

    // fall back to Turso (slow)
    const client = db.getClient() orelse return error.NotInitialized;

    // batch all 5 queries into one HTTP request
    var batch = client.queryBatch(&.{
        .{ .sql = STATS_SQL },
        .{ .sql = PLATFORMS_SQL },
        .{ .sql = TAGS_SQL },
        .{ .sql = TIMELINE_SQL },
        .{ .sql = TOP_PUBS_SQL },
    }) catch return error.QueryFailed;
    defer batch.deinit();

    // extract stats (query 0)
    const stats_row = batch.getFirst(0);
    if (stats_row == null) {
        logfire.warn("dashboard: turso batch returned no stats row", .{});
    }
    const started_at = if (stats_row) |r| r.int(4) else 0;
    const searches = if (stats_row) |r| r.int(2) else 0;
    const publications = if (stats_row) |r| r.int(1) else 0;
    const documents = if (stats_row) |r| r.int(0) else 0;
    const embeddings = if (stats_row) |r| r.int(5) else 0;

    return .{
        .started_at = started_at,
        .searches = searches,
        .publications = publications,
        .documents = documents,
        .embeddings = embeddings,
        .tags_json = try formatTagsJson(alloc, batch.get(2)),
        .timeline_json = try formatTimelineJson(alloc, batch.get(3)),
        .top_pubs_json = try formatPubsJson(alloc, batch.get(4)),
        .platforms_json = try formatPlatformsJson(alloc, batch.get(1)),
        .timing_json = try formatTimingJson(alloc),
    };
}

fn fetchLocal(alloc: Allocator, local: *db.LocalDb) !Data {
    // get stats from Turso (searches/started_at don't sync to local replica)
    const client = db.getClient() orelse return error.NotInitialized;
    var stats_res = client.query(
        \\SELECT total_searches, service_started_at FROM stats WHERE id = 1
    , &.{}) catch return error.QueryFailed;
    defer stats_res.deinit();
    const turso_stats = stats_res.first();
    const searches = if (turso_stats) |r| r.int(0) else 0;
    const started_at = if (turso_stats) |r| r.int(1) else 0;

    // get document/publication/embedding counts from local (fast)
    var counts_rows = try local.query(
        \\SELECT
        \\  (SELECT COUNT(*) FROM documents) as docs,
        \\  (SELECT COUNT(*) FROM publications) as pubs,
        \\  (SELECT COUNT(*) FROM documents WHERE embedded_at IS NOT NULL) as embeddings
    , .{});
    defer counts_rows.deinit();
    const counts_row = counts_rows.next() orelse return error.NoStats;
    const documents = counts_row.int(0);
    const publications = counts_row.int(1);
    const embeddings = counts_row.int(2);

    // platforms query
    var platforms_rows = try local.query(PLATFORMS_SQL, .{});
    defer platforms_rows.deinit();
    const platforms_json = try formatPlatformsJsonLocal(alloc, &platforms_rows);

    // tags query
    var tags_rows = try local.query(TAGS_SQL, .{});
    defer tags_rows.deinit();
    const tags_json = try formatTagsJsonLocal(alloc, &tags_rows);

    // timeline query
    var timeline_rows = try local.query(TIMELINE_SQL, .{});
    defer timeline_rows.deinit();
    const timeline_json = try formatTimelineJsonLocal(alloc, &timeline_rows);

    // top pubs query
    var pubs_rows = try local.query(TOP_PUBS_SQL, .{});
    defer pubs_rows.deinit();
    const top_pubs_json = try formatPubsJsonLocal(alloc, &pubs_rows);

    return .{
        .started_at = started_at,
        .searches = searches,
        .publications = publications,
        .documents = documents,
        .embeddings = embeddings,
        .tags_json = tags_json,
        .timeline_json = timeline_json,
        .top_pubs_json = top_pubs_json,
        .platforms_json = platforms_json,
        .timing_json = try formatTimingJson(alloc),
    };
}

fn formatTagsJsonLocal(alloc: Allocator, rows: *db.LocalDb.Rows) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    while (rows.next()) |row| {
        try jw.write(TagJson{ .tag = row.text(0), .count = row.int(1) });
    }
    try jw.endArray();
    return try output.toOwnedSlice();
}

fn formatTimelineJsonLocal(alloc: Allocator, rows: *db.LocalDb.Rows) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    while (rows.next()) |row| {
        try jw.write(TimelineJson{ .date = row.text(0), .count = row.int(1) });
    }
    try jw.endArray();
    return try output.toOwnedSlice();
}

fn formatPubsJsonLocal(alloc: Allocator, rows: *db.LocalDb.Rows) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    while (rows.next()) |row| {
        try jw.write(PubJson{ .name = row.text(0), .basePath = row.text(1), .count = row.int(2) });
    }
    try jw.endArray();
    return try output.toOwnedSlice();
}

fn formatPlatformsJsonLocal(alloc: Allocator, rows: *db.LocalDb.Rows) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    while (rows.next()) |row| {
        try jw.write(PlatformJson{ .platform = row.text(0), .count = row.int(1) });
    }
    try jw.endArray();
    return try output.toOwnedSlice();
}

fn formatTagsJson(alloc: Allocator, rows: []const db.Row) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (rows) |row| try jw.write(TagJson{ .tag = row.text(0), .count = row.int(1) });
    try jw.endArray();
    return try output.toOwnedSlice();
}

fn formatTimelineJson(alloc: Allocator, rows: []const db.Row) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (rows) |row| try jw.write(TimelineJson{ .date = row.text(0), .count = row.int(1) });
    try jw.endArray();
    return try output.toOwnedSlice();
}

fn formatPubsJson(alloc: Allocator, rows: []const db.Row) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (rows) |row| try jw.write(PubJson{ .name = row.text(0), .basePath = row.text(1), .count = row.int(2) });
    try jw.endArray();
    return try output.toOwnedSlice();
}

fn formatPlatformsJson(alloc: Allocator, rows: []const db.Row) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (rows) |row| try jw.write(PlatformJson{ .platform = row.text(0), .count = row.int(1) });
    try jw.endArray();
    return try output.toOwnedSlice();
}

fn formatTimingJson(alloc: Allocator) ![]const u8 {
    const all_timing = timing.getAllStats();
    const all_series = timing.getAllTimeSeries();

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var jw: json.Stringify = .{ .writer = &output.writer };

    try jw.beginObject();
    inline for (@typeInfo(timing.Endpoint).@"enum".fields, 0..) |field, i| {
        const t = all_timing[i];
        const series = all_series[i];
        try jw.objectField(field.name);
        try jw.beginObject();
        try jw.objectField("count");
        try jw.write(t.count);
        try jw.objectField("avg_ms");
        try jw.write(t.avg_ms);
        try jw.objectField("p50_ms");
        try jw.write(t.p50_ms);
        try jw.objectField("p95_ms");
        try jw.write(t.p95_ms);
        try jw.objectField("p99_ms");
        try jw.write(t.p99_ms);
        try jw.objectField("max_ms");
        try jw.write(t.max_ms);
        // add 24h time series
        try jw.objectField("history");
        try jw.beginArray();
        for (series) |point| {
            try jw.beginObject();
            try jw.objectField("hour");
            try jw.write(point.hour);
            try jw.objectField("count");
            try jw.write(point.count);
            try jw.objectField("avg_ms");
            try jw.write(point.avg_ms);
            try jw.objectField("max_ms");
            try jw.write(point.max_ms);
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
    }
    try jw.endObject();

    return try output.toOwnedSlice();
}

/// Generate dashboard data as JSON for API endpoint
pub fn toJson(alloc: Allocator, data: Data) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginObject();

    try jw.objectField("startedAt");
    try jw.write(data.started_at);

    try jw.objectField("searches");
    try jw.write(data.searches);

    try jw.objectField("publications");
    try jw.write(data.publications);

    try jw.objectField("documents");
    try jw.write(data.documents);

    try jw.objectField("embeddings");
    try jw.write(data.embeddings);

    try jw.objectField("platforms");
    try jw.beginWriteRaw();
    try jw.writer.writeAll(data.platforms_json);
    jw.endWriteRaw();

    // use beginWriteRaw/endWriteRaw for pre-formatted JSON arrays
    try jw.objectField("tags");
    try jw.beginWriteRaw();
    try jw.writer.writeAll(data.tags_json);
    jw.endWriteRaw();

    try jw.objectField("timeline");
    try jw.beginWriteRaw();
    try jw.writer.writeAll(data.timeline_json);
    jw.endWriteRaw();

    try jw.objectField("topPubs");
    try jw.beginWriteRaw();
    try jw.writer.writeAll(data.top_pubs_json);
    jw.endWriteRaw();

    try jw.objectField("timing");
    try jw.beginWriteRaw();
    try jw.writer.writeAll(data.timing_json);
    jw.endWriteRaw();

    try jw.endObject();
    return try output.toOwnedSlice();
}
