const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const db = @import("db/mod.zig");
const zql = @import("zql");

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

pub fn fetch(alloc: Allocator) !DashboardData {
    const stats = db.getStats();
    const doc_types = getDocTypeStats();

    return .{
        .started_at = stats.started_at,
        .searches = stats.searches,
        .publications = stats.publications,
        .articles = doc_types.articles,
        .looseleafs = doc_types.looseleafs,
        .tags_json = db.getTags(alloc) catch "[]",
        .timeline_json = getDocsByDate(alloc) catch "[]",
        .top_pubs_json = getTopPublications(alloc) catch "[]",
    };
}

fn getDocTypeStats() struct { articles: i64, looseleafs: i64 } {
    const client = db.getClient() orelse return .{ .articles = 0, .looseleafs = 0 };

    var res = client.query(
        \\SELECT
        \\  SUM(CASE WHEN publication_uri != '' THEN 1 ELSE 0 END) as articles,
        \\  SUM(CASE WHEN publication_uri = '' OR publication_uri IS NULL THEN 1 ELSE 0 END) as looseleafs
        \\FROM documents
    , &.{}) catch return .{ .articles = 0, .looseleafs = 0 };
    defer res.deinit();

    const row = res.first() orelse return .{ .articles = 0, .looseleafs = 0 };
    return .{ .articles = row.int(0), .looseleafs = row.int(1) };
}

const DateCount = struct {
    date: []const u8,
    count: i64,

    fn fromRow(row: db.Row) DateCount {
        return .{ .date = row.text(0), .count = row.int(1) };
    }
};

const DocsByDateQuery = zql.Query(
    \\SELECT DATE(created_at) as date, COUNT(*) as count
    \\FROM documents
    \\WHERE created_at IS NOT NULL AND created_at != ''
    \\GROUP BY DATE(created_at)
    \\ORDER BY date DESC
    \\LIMIT 30
);

fn getDocsByDate(alloc: Allocator) ![]const u8 {
    const client = db.getClient() orelse return error.NotInitialized;

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var res = client.query(DocsByDateQuery.positional, &.{}) catch {
        try output.writer.writeAll("[]");
        return try output.toOwnedSlice();
    };
    defer res.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();

    for (res.rows) |row| {
        const dc = DateCount.fromRow(row);
        try jw.beginObject();
        try jw.objectField("date");
        try jw.write(dc.date);
        try jw.objectField("count");
        try jw.write(dc.count);
        try jw.endObject();
    }

    try jw.endArray();
    return try output.toOwnedSlice();
}

const TopPub = struct {
    name: []const u8,
    base_path: []const u8,
    count: i64,

    fn fromRow(row: db.Row) TopPub {
        return .{ .name = row.text(0), .base_path = row.text(1), .count = row.int(2) };
    }
};

const TopPubsQuery = zql.Query(
    \\SELECT p.name, p.base_path, COUNT(d.uri) as doc_count
    \\FROM publications p
    \\JOIN documents d ON d.publication_uri = p.uri
    \\GROUP BY p.uri
    \\ORDER BY doc_count DESC
    \\LIMIT 8
);

fn getTopPublications(alloc: Allocator) ![]const u8 {
    const client = db.getClient() orelse return error.NotInitialized;

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var res = client.query(TopPubsQuery.positional, &.{}) catch {
        try output.writer.writeAll("[]");
        return try output.toOwnedSlice();
    };
    defer res.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();

    for (res.rows) |row| {
        const p = TopPub.fromRow(row);
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(p.name);
        try jw.objectField("basePath");
        try jw.write(p.base_path);
        try jw.objectField("count");
        try jw.write(p.count);
        try jw.endObject();
    }

    try jw.endArray();
    return try output.toOwnedSlice();
}
