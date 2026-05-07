const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const db = @import("../db.zig");
const logfire = @import("logfire");
const timing = @import("../metrics.zig").timing;
const stats_buffer = @import("../metrics.zig").buffer;

// JSON output types
const TagJson = struct { tag: []const u8, count: i64 };
const TimelineJson = struct { date: []const u8, count: i64, bridgyfed: i64 };
const PubJson = struct { name: []const u8, basePath: []const u8, count: i64 };
const PlatformJson = struct { platform: []const u8, count: i64 };

/// Time range for the indexing timeline.
///
/// Bucket sizes are chosen to keep bar counts bounded:
///   d7/d30/d90 -> daily, y1 -> weekly, all_time -> monthly.
pub const TimelineRange = enum {
    d7,
    d30,
    d90,
    y1,
    all_time,

    pub fn fromString(s: []const u8) TimelineRange {
        if (std.mem.eql(u8, s, "7d")) return .d7;
        if (std.mem.eql(u8, s, "30d")) return .d30;
        if (std.mem.eql(u8, s, "90d")) return .d90;
        if (std.mem.eql(u8, s, "1y")) return .y1;
        if (std.mem.eql(u8, s, "all")) return .all_time;
        return .d30;
    }

    pub fn bucketLabel(self: TimelineRange) []const u8 {
        return switch (self) {
            .d7, .d30, .d90 => "daily",
            .y1 => "weekly",
            .all_time => "monthly",
        };
    }

    fn sql(self: TimelineRange) []const u8 {
        return switch (self) {
            .d7 =>
            \\SELECT DATE(indexed_at) as date, COUNT(*) as count,
            \\  SUM(CASE WHEN COALESCE(is_bridgyfed, 0) = 1 THEN 1 ELSE 0 END) as bridgyfed
            \\FROM documents
            \\WHERE indexed_at IS NOT NULL AND indexed_at != ''
            \\AND DATE(indexed_at) <= DATE('now')
            \\AND DATE(indexed_at) >= DATE('now', '-6 days')
            \\GROUP BY DATE(indexed_at)
            \\ORDER BY date DESC
            ,
            .d30 =>
            \\SELECT DATE(indexed_at) as date, COUNT(*) as count,
            \\  SUM(CASE WHEN COALESCE(is_bridgyfed, 0) = 1 THEN 1 ELSE 0 END) as bridgyfed
            \\FROM documents
            \\WHERE indexed_at IS NOT NULL AND indexed_at != ''
            \\AND DATE(indexed_at) <= DATE('now')
            \\AND DATE(indexed_at) >= DATE('now', '-29 days')
            \\GROUP BY DATE(indexed_at)
            \\ORDER BY date DESC
            ,
            .d90 =>
            \\SELECT DATE(indexed_at) as date, COUNT(*) as count,
            \\  SUM(CASE WHEN COALESCE(is_bridgyfed, 0) = 1 THEN 1 ELSE 0 END) as bridgyfed
            \\FROM documents
            \\WHERE indexed_at IS NOT NULL AND indexed_at != ''
            \\AND DATE(indexed_at) <= DATE('now')
            \\AND DATE(indexed_at) >= DATE('now', '-89 days')
            \\GROUP BY DATE(indexed_at)
            \\ORDER BY date DESC
            ,
            .y1 =>
            \\SELECT DATE(indexed_at, 'weekday 0', '-6 days') as date, COUNT(*) as count,
            \\  SUM(CASE WHEN COALESCE(is_bridgyfed, 0) = 1 THEN 1 ELSE 0 END) as bridgyfed
            \\FROM documents
            \\WHERE indexed_at IS NOT NULL AND indexed_at != ''
            \\AND DATE(indexed_at) <= DATE('now')
            \\AND DATE(indexed_at) >= DATE('now', '-364 days')
            \\GROUP BY DATE(indexed_at, 'weekday 0', '-6 days')
            \\ORDER BY date DESC
            ,
            .all_time =>
            \\SELECT strftime('%Y-%m-01', indexed_at) as date, COUNT(*) as count,
            \\  SUM(CASE WHEN COALESCE(is_bridgyfed, 0) = 1 THEN 1 ELSE 0 END) as bridgyfed
            \\FROM documents
            \\WHERE indexed_at IS NOT NULL AND indexed_at != ''
            \\AND DATE(indexed_at) <= DATE('now')
            \\GROUP BY strftime('%Y-%m-01', indexed_at)
            \\ORDER BY date DESC
            ,
        };
    }
};

/// All data needed to render the dashboard
pub const Data = struct {
    started_at: i64,
    searches: i64,
    publications: i64,
    documents: i64,
    embeddings: i64,
    bridgyfed_documents: i64,
    relay_url: []const u8,
    tags_json: []const u8,
    timeline_json: []const u8,
    top_pubs_json: []const u8,
    platforms_json: []const u8,
    timing_json: []const u8,
    traffic_json: []const u8,
};

fn getRelayUrl() []const u8 {
    return if (std.c.getenv("TAP_RELAY_URL")) |p| std.mem.span(p) else "unknown";
}

// all dashboard queries batched into one request
const STATS_SQL =
    \\SELECT
    \\  (SELECT COUNT(*) FROM documents) as docs,
    \\  (SELECT COUNT(*) FROM publications) as pubs,
    \\  (SELECT total_searches FROM stats WHERE id = 1) as searches,
    \\  (SELECT total_errors FROM stats WHERE id = 1) as errors,
    \\  (SELECT service_started_at FROM stats WHERE id = 1) as started_at,
    \\  (SELECT COUNT(*) FROM documents WHERE embedded_at IS NOT NULL) as embeddings,
    \\  (SELECT COUNT(*) FROM documents WHERE COALESCE(is_bridgyfed, 0) = 1) as bridgyfed
;

const PLATFORMS_SQL =
    \\SELECT CASE WHEN COALESCE(is_bridgyfed, 0) = 1 THEN 'bridgy fed'
    \\  ELSE platform END as platform,
    \\  COUNT(*) as count
    \\FROM documents
    \\GROUP BY CASE WHEN COALESCE(is_bridgyfed, 0) = 1 THEN 'bridgy fed'
    \\  ELSE platform END
    \\ORDER BY count DESC
;

pub const TAGS_SQL =
    \\SELECT tag, COUNT(*) as count
    \\FROM document_tags
    \\GROUP BY tag
    \\ORDER BY count DESC
    \\LIMIT 100
;

// default timeline range for /api/dashboard (kept for back-compat)
const DEFAULT_TIMELINE_RANGE: TimelineRange = .d30;

const TOP_PUBS_SQL =
    \\SELECT p.name, p.base_path, COUNT(d.uri) as doc_count
    \\FROM publications p
    \\JOIN documents d ON d.publication_uri = p.uri
    \\WHERE COALESCE(d.is_bridgyfed, 0) = 0
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
        .{ .sql = DEFAULT_TIMELINE_RANGE.sql() },
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
    const bridgyfed_documents = if (stats_row) |r| r.int(6) else 0;

    return .{
        .started_at = started_at,
        .searches = searches,
        .publications = publications,
        .documents = documents,
        .embeddings = embeddings,
        .bridgyfed_documents = bridgyfed_documents,
        .relay_url = getRelayUrl(),
        .tags_json = try formatTagsJson(alloc, batch.get(2)),
        .timeline_json = try formatTimelineJson(alloc, batch.get(3)),
        .top_pubs_json = try formatPubsJson(alloc, batch.get(4)),
        .platforms_json = try formatPlatformsJson(alloc, batch.get(1)),
        .timing_json = try formatTimingJson(alloc),
        .traffic_json = try formatTrafficJson(alloc),
    };
}

fn fetchLocal(alloc: Allocator, local: *db.LocalDb) !Data {
    // pull cached stats from the in-memory buffer instead of querying turso.
    // total_searches / service_started_at don't live on the local replica
    // (only sync-tracked tables do), but the stats_buffer module already
    // refreshes them in the background every 5s. a synchronous turso call
    // here would hang the *entire* dashboard handler for as long as turso
    // takes to respond — and on 2026-05-07 turso had a ~95s hiccup that did
    // exactly that, leaving fly proxy to 502 every dashboard request.
    //
    // the cached values can be up to ~5s stale, which is fine for a stats
    // counter rendered on a debug page.
    const cached = stats_buffer.getCachedStats();
    const searches = if (cached) |c| c.searches else 0;
    const started_at = if (cached) |c| c.started_at else 0;

    // get document/publication/embedding counts from local (fast)
    var counts_rows = try local.query(
        \\SELECT
        \\  (SELECT COUNT(*) FROM documents) as docs,
        \\  (SELECT COUNT(*) FROM publications) as pubs,
        \\  (SELECT COUNT(*) FROM documents WHERE embedded_at IS NOT NULL) as embeddings,
        \\  (SELECT COUNT(*) FROM documents WHERE COALESCE(is_bridgyfed, 0) = 1) as bridgyfed
    , .{});
    defer counts_rows.deinit();
    const counts_row = counts_rows.next() orelse return error.NoStats;
    const documents = counts_row.int(0);
    const publications = counts_row.int(1);
    const embeddings = counts_row.int(2);
    const bridgyfed_documents = counts_row.int(3);

    // platforms query
    var platforms_rows = try local.query(PLATFORMS_SQL, .{});
    defer platforms_rows.deinit();
    const platforms_json = try formatPlatformsJsonLocal(alloc, &platforms_rows);

    // tags query
    var tags_rows = try local.query(TAGS_SQL, .{});
    defer tags_rows.deinit();
    const tags_json = try formatTagsJsonLocal(alloc, &tags_rows);

    // timeline query
    var timeline_rows = try local.query(DEFAULT_TIMELINE_RANGE.sql(), .{});
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
        .bridgyfed_documents = bridgyfed_documents,
        .relay_url = getRelayUrl(),
        .tags_json = tags_json,
        .timeline_json = timeline_json,
        .top_pubs_json = top_pubs_json,
        .platforms_json = platforms_json,
        .timing_json = try formatTimingJson(alloc),
        .traffic_json = try formatTrafficJson(alloc),
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
        try jw.write(TimelineJson{ .date = row.text(0), .count = row.int(1), .bridgyfed = row.int(2) });
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
    for (rows) |row| try jw.write(TimelineJson{ .date = row.text(0), .count = row.int(1), .bridgyfed = row.int(2) });
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

fn formatTrafficJson(alloc: Allocator) ![]const u8 {
    const series = timing.getTrafficSeries();

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var jw: json.Stringify = .{ .writer = &output.writer };

    try jw.beginArray();
    for (series) |point| {
        try jw.beginObject();
        try jw.objectField("hour");
        try jw.write(point.hour);
        try jw.objectField("count");
        try jw.write(point.count);
        try jw.endObject();
    }
    try jw.endArray();

    return try output.toOwnedSlice();
}

/// Fetch the documents-indexed timeline at the requested range.
/// Returns a JSON object: `{"bucket":"daily|weekly|monthly","range":"30d","points":[...]}`.
pub fn fetchTimeline(alloc: Allocator, range: TimelineRange) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var jw: json.Stringify = .{ .writer = &output.writer };

    try jw.beginObject();
    try jw.objectField("bucket");
    try jw.write(range.bucketLabel());
    try jw.objectField("range");
    try jw.write(@tagName(range));
    try jw.objectField("points");

    // local + turso queries both take comptime SQL — dispatch on the range tag
    // and run the matching comptime-known query string in each branch
    switch (range) {
        .d7 => try writeTimelinePoints(&jw, comptime TimelineRange.d7.sql()),
        .d30 => try writeTimelinePoints(&jw, comptime TimelineRange.d30.sql()),
        .d90 => try writeTimelinePoints(&jw, comptime TimelineRange.d90.sql()),
        .y1 => try writeTimelinePoints(&jw, comptime TimelineRange.y1.sql()),
        .all_time => try writeTimelinePoints(&jw, comptime TimelineRange.all_time.sql()),
    }

    try jw.endObject();
    return try output.toOwnedSlice();
}

fn writeTimelinePoints(jw: *json.Stringify, comptime sql_query: []const u8) !void {
    // try local SQLite first
    if (db.getLocalDb()) |local| {
        if (local.query(sql_query, .{})) |rows_const| {
            var rows = rows_const;
            defer rows.deinit();
            try jw.beginArray();
            while (rows.next()) |row| {
                try jw.write(TimelineJson{ .date = row.text(0), .count = row.int(1), .bridgyfed = row.int(2) });
            }
            try jw.endArray();
            return;
        } else |err| {
            logfire.warn("dashboard: timeline local query failed: {s}, falling back to turso", .{@errorName(err)});
        }
    }

    // fall back to Turso
    const client = db.getClient() orelse return error.NotInitialized;
    var res = client.query(sql_query, &.{}) catch return error.QueryFailed;
    defer res.deinit();

    try jw.beginArray();
    for (res.rows) |row| {
        try jw.write(TimelineJson{ .date = row.text(0), .count = row.int(1), .bridgyfed = row.int(2) });
    }
    try jw.endArray();
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

    try jw.objectField("bridgyfedDocuments");
    try jw.write(data.bridgyfed_documents);

    try jw.objectField("relayUrl");
    try jw.write(data.relay_url);

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

    try jw.objectField("trafficHistory");
    try jw.beginWriteRaw();
    try jw.writer.writeAll(data.traffic_json);
    jw.endWriteRaw();

    try jw.endObject();
    return try output.toOwnedSlice();
}
