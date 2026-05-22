//! /curators — leaderboard of people who recommend the most.
//!
//! Flips the axis of /recommended: instead of "which docs have the most
//! recommenders," this answers "which recommenders have given out the most
//! recommends." A different lens — surfacing curators / tastemakers, not
//! creators.
//!
//! Same caching shape as /recommended: a WindowedJsonCache(Window) keeps
//! the slow Turso GROUP BY off the hot path. No author/sort dimensions
//! here — there's only one natural metric (recommend count) and the entity
//! itself (DID) is what varies.
//!
//! Frontend resolves DIDs → handles client-side via bsky's getProfiles,
//! same as search results.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;
const zql = @import("zql");

const db = @import("../db.zig");
const recommended = @import("recommended.zig");
const cache = @import("cache.zig");

/// Reuse the Window enum from /recommended so the cache slot shape +
/// URL semantics match. Less to remember, less to drift.
pub const Window = recommended.Window;

const Query = zql.Query(
    \\SELECT r.did AS did,
    \\  COUNT(DISTINCT CASE
    \\    WHEN DATE(COALESCE(NULLIF(r.created_at, ''), r.indexed_at)) >= DATE('now', ?)
    \\    THEN r.uri END) AS recommend_count,
    \\  COUNT(DISTINCT r.uri) AS total_recommends,
    \\  COUNT(DISTINCT r.document_uri) AS unique_docs,
    \\  MAX(COALESCE(NULLIF(r.created_at, ''), r.indexed_at)) AS last_at
    \\FROM recommends r
    \\GROUP BY r.did
    \\HAVING recommend_count > 0
    \\ORDER BY recommend_count DESC, last_at DESC
    \\LIMIT 250
);

const Row = struct {
    did: []const u8,
    recommend_count: i64,
    total_recommends: i64,
    unique_docs: i64,
    last_at: []const u8,
};

const JsonRow = struct {
    did: []const u8,
    /// recommends given out WITHIN the chosen window (drives rank).
    recommendCount: i64,
    /// recommends given out ALL-TIME (shown alongside the rank).
    totalRecommends: i64,
    /// distinct documents this curator has recommended ever.
    uniqueDocs: i64,
    /// timestamp of this curator's most recent recommend (ISO 8601).
    lastRecommendAt: []const u8,
};

pub fn fetch(alloc: Allocator, window: Window) ![]const u8 {
    const c = db.getClient() orelse return error.NotInitialized;

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var res = c.query(Query.positional, &.{window.dateModifier()}) catch {
        try output.writer.writeAll("{\"error\":\"failed to fetch curators\"}");
        return try output.toOwnedSlice();
    };
    defer res.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (res.rows) |row| {
        const r = Query.fromRow(Row, row);
        try jw.write(JsonRow{
            .did = r.did,
            .recommendCount = r.recommend_count,
            .totalRecommends = r.total_recommends,
            .uniqueDocs = r.unique_docs,
            .lastRecommendAt = r.last_at,
        });
    }
    try jw.endArray();
    return try output.toOwnedSlice();
}

fn refreshCb(slot: Window, alloc: Allocator) anyerror![]const u8 {
    return fetch(alloc, slot);
}

pub const Cache = cache.WindowedJsonCache(Window, .{
    .name = "curators",
    .refresh = &refreshCb,
});

pub fn init(io: Io) void {
    Cache.init(io);
}

/// Reuse recommended.sliceJson — both endpoints cache a full top-N JSON
/// array and slice per-request for pagination. The slicer is structure-
/// agnostic (operates on json.Value), so it works for curator rows too.
pub const sliceJson = recommended.sliceJson;
