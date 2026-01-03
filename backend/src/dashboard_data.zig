const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const db = @import("db/mod.zig");

/// All data needed to render the dashboard
pub const DashboardData = struct {
    started_at: i64,
    searches: i64,
    publications: i64,
    articles: i64,
    looseleafs: i64,
    tags_json: []const u8,
    timeline_json: []const u8,
    top_pubs_json: []const u8,
};

// all dashboard queries batched into one request
const STATS_SQL =
    \\SELECT
    \\  (SELECT COUNT(*) FROM documents) as docs,
    \\  (SELECT COUNT(*) FROM publications) as pubs,
    \\  (SELECT total_searches FROM stats WHERE id = 1) as searches,
    \\  (SELECT total_errors FROM stats WHERE id = 1) as errors,
    \\  (SELECT service_started_at FROM stats WHERE id = 1) as started_at
;

const DOC_TYPES_SQL =
    \\SELECT
    \\  SUM(CASE WHEN publication_uri != '' THEN 1 ELSE 0 END) as articles,
    \\  SUM(CASE WHEN publication_uri = '' OR publication_uri IS NULL THEN 1 ELSE 0 END) as looseleafs
    \\FROM documents
;

const TAGS_SQL =
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

pub fn fetch(alloc: Allocator) !DashboardData {
    const client = db.getClient() orelse return error.NotInitialized;

    // batch all 5 queries into one HTTP request
    var batch = client.queryBatch(&.{
        .{ .sql = STATS_SQL },
        .{ .sql = DOC_TYPES_SQL },
        .{ .sql = TAGS_SQL },
        .{ .sql = TIMELINE_SQL },
        .{ .sql = TOP_PUBS_SQL },
    }) catch return error.QueryFailed;
    defer batch.deinit();

    // extract stats (query 0)
    const stats_row = batch.getFirst(0);
    const started_at = if (stats_row) |r| r.int(4) else 0;
    const searches = if (stats_row) |r| r.int(2) else 0;
    const publications = if (stats_row) |r| r.int(1) else 0;

    // extract doc types (query 1)
    const doc_row = batch.getFirst(1);
    const articles = if (doc_row) |r| r.int(0) else 0;
    const looseleafs = if (doc_row) |r| r.int(1) else 0;

    return .{
        .started_at = started_at,
        .searches = searches,
        .publications = publications,
        .articles = articles,
        .looseleafs = looseleafs,
        .tags_json = try formatTagsJson(alloc, batch.get(2)),
        .timeline_json = try formatTimelineJson(alloc, batch.get(3)),
        .top_pubs_json = try formatPubsJson(alloc, batch.get(4)),
    };
}

fn formatTagsJson(alloc: Allocator, rows: []const db.Row) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();

    for (rows) |row| {
        try jw.beginObject();
        try jw.objectField("tag");
        try jw.write(row.text(0));
        try jw.objectField("count");
        try jw.write(row.int(1));
        try jw.endObject();
    }

    try jw.endArray();
    return try output.toOwnedSlice();
}

fn formatTimelineJson(alloc: Allocator, rows: []const db.Row) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();

    for (rows) |row| {
        try jw.beginObject();
        try jw.objectField("date");
        try jw.write(row.text(0));
        try jw.objectField("count");
        try jw.write(row.int(1));
        try jw.endObject();
    }

    try jw.endArray();
    return try output.toOwnedSlice();
}

fn formatPubsJson(alloc: Allocator, rows: []const db.Row) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();

    for (rows) |row| {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(row.text(0));
        try jw.objectField("basePath");
        try jw.write(row.text(1));
        try jw.objectField("count");
        try jw.write(row.int(2));
        try jw.endObject();
    }

    try jw.endArray();
    return try output.toOwnedSlice();
}
