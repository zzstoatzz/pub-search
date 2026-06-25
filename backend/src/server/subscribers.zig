//! /subscribers — WHO is subscribed.
//!
//! Opens up the COUNT(DISTINCT did) aggregate behind /subscribed, returning the
//! actual subscriber DIDs so the UI can show "subscribed by @a, @b, @c" — and
//! so anyone can see who's subscribed to them. Two scopes mirror the two
//! /subscribed views:
//!   - `?publication=<at-uri>` — subscribers of one publication.
//!   - `?did=<owner-did>`      — subscribers across ALL publications that owner
//!                               owns (deduped — the people-view drill-down).
//!
//! Deduped by subscriber did, recency-ordered. The frontend resolves DIDs →
//! handles client-side, same as the recommenders/curators views.
//!
//! Local-replica-first (single-digit ms, no turso read); falls back to turso
//! when the replica's subscriptions table is empty (pre-schema-v3 snapshots)
//! or errors.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const zql = @import("zql");
const logfire = @import("logfire");

const db = @import("../db.zig");
const pubkey = @import("pubkey.zig");

// Two positional params: the publication's (did, rkey). Collection-agnostic so
// subscribers who referenced the OTHER dual-write collection's at-uri are still
// counted — keeps this drill-down in lockstep with the /subscribed leaderboard,
// which now also matches by (did, rkey). See pubkey.zig.
const ByPublicationQuery = zql.Query(
    \\SELECT did,
    \\  MAX(COALESCE(NULLIF(created_at, ''), indexed_at)) AS subscribed_at
    \\FROM subscriptions
    \\WHERE
++ " " ++ pubkey.didExpr("publication_uri") ++ " = ? AND " ++ pubkey.rkeyExpr("publication_uri") ++ " = ?\n" ++
    \\GROUP BY did
    \\ORDER BY subscribed_at DESC
    \\LIMIT 200
);

// One positional param: the owner DID. Subscribers across every publication
// that DID owns; the GROUP BY did + MAX dedupes someone who follows several
// of the owner's pubs to their most-recent subscribe.
const ByOwnerQuery = zql.Query(
    \\SELECT s.did AS did,
    \\  MAX(COALESCE(NULLIF(s.created_at, ''), s.indexed_at)) AS subscribed_at
    \\FROM subscriptions s
    \\JOIN publications p ON
++ " " ++ pubkey.joinOn("p", "s.publication_uri") ++ "\n" ++
    \\WHERE p.did = ?
    \\GROUP BY s.did
    \\ORDER BY subscribed_at DESC
    \\LIMIT 200
);

const Row = struct {
    did: []const u8,
    subscribed_at: []const u8,
};

const JsonRow = struct {
    did: []const u8,
    /// most recent time this person subscribed (ISO 8601).
    subscribedAt: []const u8,
};

pub const Scope = union(enum) {
    publication: []const u8,
    owner: []const u8,
};

/// Subscribers for `scope`. Local-first, turso fallback.
pub fn fetch(alloc: Allocator, scope: Scope) ![]const u8 {
    if (db.getLocalDb()) |local| {
        if (fetchLocal(alloc, local, scope)) |body| {
            return body;
        } else |err| {
            logfire.warn("subscribers local failed, turso fallback: {s}", .{@errorName(err)});
        }
    }
    return fetchTurso(alloc, scope);
}

fn scopeKey(scope: Scope) []const u8 {
    return switch (scope) {
        .publication => |v| v,
        .owner => |v| v,
    };
}

fn fetchLocal(alloc: Allocator, local: *db.LocalDb, scope: Scope) ![]const u8 {
    // pre-v3 snapshots ship an empty (boot-created) subscriptions table — bail
    // to the turso path rather than return a falsely-empty list.
    {
        var check = try local.query("SELECT COUNT(*) FROM subscriptions", .{});
        defer check.deinit();
        const row = check.next() orelse return error.NoLocalSubscriptions;
        if (row.int(0) == 0) return error.NoLocalSubscriptions;
    }

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var rows = switch (scope) {
        .publication => |uri| blk: {
            const k = pubkey.parse(uri) orelse return error.BadPublicationUri;
            break :blk try local.query(ByPublicationQuery.positional, .{ k.did, k.rkey });
        },
        .owner => |did| try local.query(ByOwnerQuery.positional, .{did}),
    };
    defer rows.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    while (rows.next()) |row| {
        try jw.write(JsonRow{
            .did = row.text(0),
            .subscribedAt = row.text(1),
        });
    }
    if (rows.err()) |e| return e;
    try jw.endArray();
    return try output.toOwnedSlice();
}

fn fetchTurso(alloc: Allocator, scope: Scope) ![]const u8 {
    const c = db.getClient() orelse return error.NotInitialized;

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    const key = scopeKey(scope);
    const pub_parts: ?pubkey.Parsed = switch (scope) {
        .publication => pubkey.parse(key),
        .owner => null,
    };
    var res = switch (scope) {
        .publication => if (pub_parts) |k|
            c.query(ByPublicationQuery.positional, &.{ k.did, k.rkey })
        else
            c.query(ByPublicationQuery.positional, &.{ "", "" }),
        .owner => c.query(ByOwnerQuery.positional, &.{key}),
    } catch {
        try output.writer.writeAll("{\"error\":\"failed to fetch subscribers\"}");
        return try output.toOwnedSlice();
    };
    defer res.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (res.rows) |row| {
        const r = ByPublicationQuery.fromRow(Row, row);
        try jw.write(JsonRow{
            .did = r.did,
            .subscribedAt = r.subscribed_at,
        });
    }
    try jw.endArray();
    return try output.toOwnedSlice();
}
