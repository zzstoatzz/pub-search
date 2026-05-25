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
    pub fn dateModifier(self: Window) []const u8 {
        return switch (self) {
            .all => "-100 years",
            .day => "-1 days",
            .week => "-7 days",
            .month => "-30 days",
            .year => "-365 days",
        };
    }
};

pub const Sort = enum {
    /// most recommenders in the window, period.
    top,
    /// recommends-per-day-since-publish — surfaces recent velocity, not raw size.
    trending,

    pub fn fromString(s: ?[]const u8) Sort {
        const str = s orelse return .top;
        if (std.mem.eql(u8, str, "trending")) return .trending;
        return .top;
    }

    pub fn slug(self: Sort) []const u8 {
        return @tagName(self);
    }
};

// Two queries with IDENTICAL column projection — only ORDER BY differs.
// `recommend_count` is windowed (drives rank); `total_count` is all-time
// (displayed). They're equal for `.all`.
//
// TopQuery: rank by raw count.
// TrendingQuery: rank by recommends-per-day-since-publish. The `+1` and
// COALESCE-to-epoch defensively handle malformed/missing created_at.
//
// Both pre-aggregate the small `recommends` table in a subquery before
// joining `documents`. The naive shape (`FROM documents d JOIN recommends
// r ...`) causes SQLite to plan a full scan of `documents` (~18k rows)
// even though only ~880 have any recommends. The subquery drives the
// scan from recommends (~2.6k rows), then looks up each matched doc by
// PK. ~6x fewer rows read per refresh. Written as subquery-in-FROM
// rather than CTE because zql's comptime parser walks forward to find
// the first SELECT/FROM pair — a `WITH … AS (SELECT … FROM …)` prefix
// would trip it into parsing the inner SELECT as the column list.
// Author/curator-filtered variants below keep the naive shape — their
// WHERE clause already narrows the document side to a handful of rows,
// so the rewrite would buy nothing.
const TopQuery = zql.Query(
    \\SELECT d.uri, d.did, d.title, COALESCE(d.created_at, '') AS created_at,
    \\  d.rkey, COALESCE(d.base_path, '') AS base_path, d.platform,
    \\  COALESCE(d.path, '') AS path, d.has_publication,
    \\  COALESCE(p.name, '') AS publication_name,
    \\  agg.recommend_count AS recommend_count,
    \\  agg.total_count AS total_count
    \\FROM (
    \\  SELECT document_uri,
    \\    COUNT(DISTINCT CASE
    \\      WHEN DATE(COALESCE(NULLIF(created_at, ''), indexed_at)) >= DATE('now', ?)
    \\      THEN did END) AS recommend_count,
    \\    COUNT(DISTINCT did) AS total_count
    \\  FROM recommends
    \\  GROUP BY document_uri
    \\  HAVING recommend_count > 0
    \\) agg
    \\JOIN documents d ON d.uri = agg.document_uri
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\ORDER BY agg.recommend_count DESC, d.created_at DESC
    \\LIMIT 250
);

const TrendingQuery = zql.Query(
    \\SELECT d.uri, d.did, d.title, COALESCE(d.created_at, '') AS created_at,
    \\  d.rkey, COALESCE(d.base_path, '') AS base_path, d.platform,
    \\  COALESCE(d.path, '') AS path, d.has_publication,
    \\  COALESCE(p.name, '') AS publication_name,
    \\  agg.recommend_count AS recommend_count,
    \\  agg.total_count AS total_count
    \\FROM (
    \\  SELECT document_uri,
    \\    COUNT(DISTINCT CASE
    \\      WHEN DATE(COALESCE(NULLIF(created_at, ''), indexed_at)) >= DATE('now', ?)
    \\      THEN did END) AS recommend_count,
    \\    COUNT(DISTINCT did) AS total_count
    \\  FROM recommends
    \\  GROUP BY document_uri
    \\  HAVING recommend_count > 0
    \\) agg
    \\JOIN documents d ON d.uri = agg.document_uri
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\ORDER BY CAST(agg.recommend_count AS REAL)
    \\  / MAX(1, julianday('now') - julianday(COALESCE(NULLIF(d.created_at, ''), '1970-01-01'))) DESC,
    \\  d.created_at DESC
    \\LIMIT 250
);

// Author-filtered variants: same shape with `WHERE d.did = ?`. Author
// queries bypass the cache (one user one author at a time = unbounded
// cache key space), so they hit Turso live. Sub-100ms because the WHERE
// drastically narrows the JOIN.
const TopByAuthorQuery = zql.Query(
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
    \\WHERE d.did = ?
    \\GROUP BY d.uri
    \\HAVING recommend_count > 0
    \\ORDER BY recommend_count DESC, d.created_at DESC
    \\LIMIT 250
);

const TrendingByAuthorQuery = zql.Query(
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
    \\WHERE d.did = ?
    \\GROUP BY d.uri
    \\HAVING recommend_count > 0
    \\ORDER BY CAST(recommend_count AS REAL)
    \\  / MAX(1, julianday('now') - julianday(COALESCE(NULLIF(d.created_at, ''), '1970-01-01'))) DESC,
    \\  d.created_at DESC
    \\LIMIT 250
);

// Curator-filtered variants: docs that a specific recommender DID has
// recommended. Different intent from author: "show me what they read &
// liked" (curator) vs "show me what they wrote that got recommended"
// (author). Uses an EXISTS subquery so the outer aggregation still counts
// ALL recommenders for each doc (the displayed total reflects popularity,
// not just this curator's contribution).
const TopByCuratorQuery = zql.Query(
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
    \\WHERE EXISTS (SELECT 1 FROM recommends r2 WHERE r2.document_uri = d.uri AND r2.did = ?)
    \\GROUP BY d.uri
    \\HAVING recommend_count > 0
    \\ORDER BY recommend_count DESC, d.created_at DESC
    \\LIMIT 250
);

const TrendingByCuratorQuery = zql.Query(
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
    \\WHERE EXISTS (SELECT 1 FROM recommends r2 WHERE r2.document_uri = d.uri AND r2.did = ?)
    \\GROUP BY d.uri
    \\HAVING recommend_count > 0
    \\ORDER BY CAST(recommend_count AS REAL)
    \\  / MAX(1, julianday('now') - julianday(COALESCE(NULLIF(d.created_at, ''), '1970-01-01'))) DESC,
    \\  d.created_at DESC
    \\LIMIT 250
);

// Comptime safety: all six queries must select the same columns in the
// same order so Row's column lookup via TopQuery works for all of them.
comptime {
    const all_queries = .{
        TopQuery,          TrendingQuery,
        TopByAuthorQuery,  TrendingByAuthorQuery,
        TopByCuratorQuery, TrendingByCuratorQuery,
    };
    for (all_queries) |Q| {
        if (Q.columns.len != TopQuery.columns.len) @compileError("recommended query column count drift");
        for (Q.columns, TopQuery.columns) |a, b| {
            if (!std.mem.eql(u8, a, b)) @compileError("recommended query column drift: " ++ a ++ " vs " ++ b);
        }
    }
}

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

/// Optional per-request filters. At most one of `author_did` / `curator_did`
/// should be set — author narrows to docs authored by that DID, curator
/// narrows to docs that DID has recommended.
pub const Filter = struct {
    author_did: ?[]const u8 = null,
    curator_did: ?[]const u8 = null,
};

/// Fetch top-250 for (window, sort), optionally narrowed by author OR
/// curator. Used by the cache refresh thread (filter empty) and the
/// cold fallback / live filter paths in the handler.
pub fn fetch(alloc: Allocator, window: Window, sort: Sort, filter: Filter) ![]const u8 {
    const c = db.getClient() orelse return error.NotInitialized;

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    // `c.query` takes a comptime SQL string, so we branch on the (filter,
    // sort) combo and call the right comptime query in each arm. The arms
    // share a common error-envelope path via the inner orelse-block.
    const date_mod = window.dateModifier();
    const failEnvelope = struct {
        fn fail(out: *std.Io.Writer.Allocating) anyerror![]const u8 {
            try out.writer.writeAll("{\"error\":\"failed to fetch recommended\"}");
            return try out.toOwnedSlice();
        }
    }.fail;

    var res = blk: {
        if (filter.curator_did) |did| {
            break :blk switch (sort) {
                .top => c.query(TopByCuratorQuery.positional, &.{ date_mod, did }) catch return failEnvelope(&output),
                .trending => c.query(TrendingByCuratorQuery.positional, &.{ date_mod, did }) catch return failEnvelope(&output),
            };
        }
        if (filter.author_did) |did| {
            break :blk switch (sort) {
                .top => c.query(TopByAuthorQuery.positional, &.{ date_mod, did }) catch return failEnvelope(&output),
                .trending => c.query(TrendingByAuthorQuery.positional, &.{ date_mod, did }) catch return failEnvelope(&output),
            };
        }
        break :blk switch (sort) {
            .top => c.query(TopQuery.positional, &.{date_mod}) catch return failEnvelope(&output),
            .trending => c.query(TrendingQuery.positional, &.{date_mod}) catch return failEnvelope(&output),
        };
    };
    defer res.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (res.rows) |row| {
        // Both queries share the column projection (asserted at comptime
        // above), so either one's fromRow works.
        const r = TopQuery.fromRow(Row, row);
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

fn refreshTop(slot: Window, alloc: Allocator) anyerror![]const u8 {
    return fetch(alloc, slot, .top, .{});
}

fn refreshTrending(slot: Window, alloc: Allocator) anyerror![]const u8 {
    return fetch(alloc, slot, .trending, .{});
}

/// Two parallel caches keyed by Sort, each storing 5 window slots. Two
/// refresh threads run in parallel (Turso handles concurrent connections
/// fine and total tick work is well under the 45s interval).
pub const TopCache = cache.WindowedJsonCache(Window, .{
    .name = "recommended.top",
    .refresh = &refreshTop,
});
pub const TrendingCache = cache.WindowedJsonCache(Window, .{
    .name = "recommended.trending",
    .refresh = &refreshTrending,
});

/// Allocator-duped cached body for (sort, window), or null if no cache
/// instance has populated it yet. Caller owns the slice.
pub fn snapshot(sort: Sort, window: Window, alloc: Allocator) !?[]u8 {
    return switch (sort) {
        .top => TopCache.snapshot(window, alloc),
        .trending => TrendingCache.snapshot(window, alloc),
    };
}

/// Spawn background refresh threads. Call from initServices.
pub fn init(io: Io) void {
    TopCache.init(io);
    TrendingCache.init(io);
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
