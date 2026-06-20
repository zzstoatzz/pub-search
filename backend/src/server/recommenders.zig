//! /recommenders — WHO recommended a given document.
//!
//! The counts on /recommended are COUNT(DISTINCT did); this endpoint opens
//! that aggregate up, returning the actual recommender DIDs for one document
//! so the UI can show "recommended by @a, @b, @c" instead of a bare number.
//!
//! Deduped by did (the same person showing up in both the standard and
//! leaflet lexicons counts once), recency-ordered. The frontend resolves
//! DIDs → handles client-side, same as the curators view.
//!
//! Per-document point lookup keyed by idx_recommends_document_uri — cheap
//! enough to run live. Local-replica-first (single-digit ms, no turso read);
//! falls back to turso when the replica's recommends table is empty
//! (pre-schema-v2 snapshots) or errors.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;
const zql = @import("zql");
const logfire = @import("logfire");

const db = @import("../db.zig");

// One positional param: the document URI. MAX(...) picks the most recent
// recommend timestamp per person across both lexicons; COALESCE handles
// rows whose created_at is missing/empty by falling back to indexed_at.
const Query = zql.Query(
    \\SELECT did,
    \\  MAX(COALESCE(NULLIF(created_at, ''), indexed_at)) AS recommended_at
    \\FROM recommends
    \\WHERE document_uri = ?
    \\GROUP BY did
    \\ORDER BY recommended_at DESC
    \\LIMIT 200
);

const Row = struct {
    did: []const u8,
    recommended_at: []const u8,
};

const JsonRow = struct {
    did: []const u8,
    /// most recent time this person recommended the doc (ISO 8601).
    recommendedAt: []const u8,
};

/// Recommenders for `document_uri`. Local-first, turso fallback.
pub fn fetch(alloc: Allocator, document_uri: []const u8) ![]const u8 {
    if (db.getLocalDb()) |local| {
        if (fetchLocal(alloc, local, document_uri)) |body| {
            return body;
        } else |err| {
            logfire.warn("recommenders local failed, turso fallback: {s}", .{@errorName(err)});
        }
    }
    return fetchTurso(alloc, document_uri);
}

fn fetchLocal(alloc: Allocator, local: *db.LocalDb, document_uri: []const u8) ![]const u8 {
    // pre-v2 snapshots ship an empty (boot-created) recommends table — bail
    // to the turso path rather than return a falsely-empty list.
    {
        var check = try local.query("SELECT COUNT(*) FROM recommends", .{});
        defer check.deinit();
        const row = check.next() orelse return error.NoLocalRecommends;
        if (row.int(0) == 0) return error.NoLocalRecommends;
    }

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var rows = try local.query(Query.positional, .{document_uri});
    defer rows.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    while (rows.next()) |row| {
        try jw.write(JsonRow{
            .did = row.text(0),
            .recommendedAt = row.text(1),
        });
    }
    if (rows.err()) |e| return e;
    try jw.endArray();
    return try output.toOwnedSlice();
}

fn fetchTurso(alloc: Allocator, document_uri: []const u8) ![]const u8 {
    const c = db.getClient() orelse return error.NotInitialized;

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var res = c.query(Query.positional, &.{document_uri}) catch {
        try output.writer.writeAll("{\"error\":\"failed to fetch recommenders\"}");
        return try output.toOwnedSlice();
    };
    defer res.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (res.rows) |row| {
        const r = Query.fromRow(Row, row);
        try jw.write(JsonRow{
            .did = r.did,
            .recommendedAt = r.recommended_at,
        });
    }
    try jw.endArray();
    return try output.toOwnedSlice();
}
