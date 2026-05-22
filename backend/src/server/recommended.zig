//! /recommended — leaderboard of most-recommended documents.
//!
//! Aggregates two distinct lexicons into one logical signal:
//!   - site.standard.graph.recommend (cross-platform)
//!   - pub.leaflet.interactions.recommend (Leaflet's own variant)
//!
//! Counts use COUNT(DISTINCT did) so the same person showing up in both
//! lexicons counts once. The ranking column (`recommend_count`) is filtered
//! to the requested window; `total_count` is always all-time so the row
//! displays a meaningful number regardless of the window.
//!
//! The underlying Turso JOIN + GROUP BY is slow (1–11s on cold connections).
//! Background-refreshed cache (one slot per Window) keeps user requests fast.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;
const zql = @import("zql");

const db = @import("../db.zig");
const search = @import("search.zig");
const cache = @import("cache.zig");

pub const Window = enum {
    all,
    day,
    week,
    month,
    year,

    pub fn fromString(s: ?[]const u8) Window {
        const str = s orelse return .all;
        if (std.mem.eql(u8, str, "day")) return .day;
        if (std.mem.eql(u8, str, "week")) return .week;
        if (std.mem.eql(u8, str, "month")) return .month;
        if (std.mem.eql(u8, str, "year")) return .year;
        return .all;
    }

    pub fn slug(self: Window) []const u8 {
        return @tagName(self);
    }

    /// SQLite modifier for `DATE('now', ...)`. `.all` uses a far-past sentinel
    /// so the same parameterized SQL works for every window.
    fn dateModifier(self: Window) []const u8 {
        return switch (self) {
            .all => "-100 years",
            .day => "-1 days",
            .week => "-7 days",
            .month => "-30 days",
            .year => "-365 days",
        };
    }
};

// One query, parameterized by date modifier. `recommend_count` is windowed
// (drives rank); `total_count` is all-time (displayed). They're equal for
// `.all`.
const Query = zql.Query(
    \\SELECT d.uri, d.did, d.title, COALESCE(d.created_at, '') AS created_at,
    \\  d.rkey, COALESCE(d.base_path, '') AS base_path, d.platform,
    \\  COALESCE(d.path, '') AS path, d.has_publication,
    \\  COALESCE(p.name, '') AS publication_name,
    \\  COUNT(DISTINCT CASE
    \\    WHEN DATE(COALESCE(NULLIF(r.created_at, ''), r.indexed_at)) >= DATE('now', ?)
    \\    THEN r.did END) AS recommend_count,
    \\  COUNT(DISTINCT r.did) AS total_count
    \\FROM documents d
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\JOIN recommends r ON r.document_uri = d.uri
    \\GROUP BY d.uri
    \\HAVING recommend_count > 0
    \\ORDER BY recommend_count DESC, d.created_at DESC
    \\LIMIT 250
);

const Row = struct {
    uri: []const u8,
    did: []const u8,
    title: []const u8,
    created_at: []const u8,
    rkey: []const u8,
    base_path: []const u8,
    platform: []const u8,
    path: []const u8,
    has_publication: bool,
    publication_name: []const u8,
    recommend_count: i64,
    total_count: i64,
};

const JsonRow = struct {
    type: []const u8,
    uri: []const u8,
    did: []const u8,
    title: []const u8,
    createdAt: []const u8,
    rkey: []const u8,
    basePath: []const u8,
    platform: []const u8,
    path: []const u8,
    publicationName: []const u8,
    url: []const u8,
    /// distinct recommenders WITHIN the chosen window (drives rank).
    recommendCount: i64,
    /// distinct recommenders ALL-TIME (shown next to the rank).
    totalCount: i64,
};

/// Fetch top-250 for `window` directly from Turso. Used by the cache refresh
/// thread and the cold fallback path in the handler.
pub fn fetch(alloc: Allocator, window: Window) ![]const u8 {
    const c = db.getClient() orelse return error.NotInitialized;

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var res = c.query(Query.positional, &.{window.dateModifier()}) catch {
        try output.writer.writeAll("{\"error\":\"failed to fetch recommended\"}");
        return try output.toOwnedSlice();
    };
    defer res.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (res.rows) |row| {
        const r = Query.fromRow(Row, row);
        const doc_type: []const u8 = if (r.has_publication) "article" else "looseleaf";
        try jw.write(JsonRow{
            .type = doc_type,
            .uri = r.uri,
            .did = r.did,
            .title = r.title,
            .createdAt = r.created_at,
            .rkey = r.rkey,
            .basePath = r.base_path,
            .platform = r.platform,
            .path = r.path,
            .publicationName = r.publication_name,
            .url = search.buildDocUrl(alloc, doc_type, r.platform, r.base_path, r.path, r.rkey, r.did),
            .recommendCount = r.recommend_count,
            .totalCount = r.total_count,
        });
    }
    try jw.endArray();
    return try output.toOwnedSlice();
}

fn refreshCb(slot: Window, alloc: Allocator) anyerror![]const u8 {
    return fetch(alloc, slot);
}

pub const Cache = cache.WindowedJsonCache(Window, .{
    .name = "recommended",
    .refresh = &refreshCb,
});

/// Spawn the background refresh thread. Call from initServices.
pub fn init(io: Io) void {
    Cache.init(io);
}

/// Parse the cached top-N JSON array and re-emit only [offset, offset+limit).
/// JSON parse for ~250 small records is sub-ms.
pub fn sliceJson(alloc: Allocator, body: []const u8, limit: usize, offset: usize) ![]const u8 {
    var parsed = json.parseFromSlice(json.Value, alloc, body, .{}) catch {
        // body was an error envelope, not an array — pass it through.
        return alloc.dupe(u8, body);
    };
    defer parsed.deinit();

    if (parsed.value != .array) return alloc.dupe(u8, body);
    const items = parsed.value.array.items;

    const start = @min(offset, items.len);
    const end = @min(start + limit, items.len);

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (items[start..end]) |item| try jw.write(item);
    try jw.endArray();
    return try output.toOwnedSlice();
}
