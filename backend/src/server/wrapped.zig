//! /wrapped?did=<did> (or ?handle=) — a single identity's standing across the
//! standard.site graph, in three lenses:
//!
//!   - publisher: their publications, how many distinct people subscribe to
//!     them, and where that ranks among all publication owners.
//!   - curator:   how many docs they've recommended (and over how many distinct
//!     documents), and where that ranks among all recommenders.
//!   - reader:    how many publications they subscribe to, since when, and a
//!     recent slice of who (for the frontend to render avatars).
//!
//! Local-replica only. Every query is a point lookup or a small GROUP BY over
//! the frozen replica (single-digit ms) — we deliberately never touch Turso
//! here, so a personal-page keyspace (unbounded per-DID) can't stampede the
//! source of truth. No cache for the same reason recommenders/subscribers
//! skip it: the per-DID keyspace is unbounded and each lookup is already cheap.
//!
//! Rank is computed with correlated subqueries so we only ever bind the DID
//! (text) — no integer round-tripping. Ranks are 1-based ("you are #N of M").

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const db = @import("../db.zig");

const TopPub = struct {
    uri: []const u8,
    name: []const u8,
    basePath: []const u8,
    subscribers: i64,
};

const Follow = struct {
    uri: []const u8,
    ownerDid: []const u8,
    name: []const u8,
    basePath: []const u8,
};

const Publisher = struct {
    /// publications this DID owns (including ones with zero subscribers).
    pubCount: i64,
    /// distinct people subscribed across all their publications.
    totalSubscribers: i64,
    /// 1-based rank among owners-with-subscribers (null when totalSubscribers==0).
    rank: ?i64,
    /// how many owners have at least one subscriber (the "of M").
    totalOwners: i64,
    /// their single most-subscribed publication (null when none).
    topPublication: ?TopPub,
};

const Curator = struct {
    /// recommends given out, all-time.
    totalRecommends: i64,
    /// distinct documents they've recommended.
    uniqueDocs: i64,
    /// 1-based rank among recommenders (null when totalRecommends==0).
    rank: ?i64,
    /// how many distinct recommenders exist (the "of M").
    totalCurators: i64,
    /// first / most-recent recommend (ISO 8601; empty when none).
    firstAt: []const u8,
    lastAt: []const u8,
};

const Reader = struct {
    /// distinct publications this DID subscribes to.
    subscriptionCount: i64,
    /// when they first subscribed to anything (ISO 8601; empty when none).
    firstAt: []const u8,
    /// recent slice of subscribed publications (for avatars), newest first.
    following: []const Follow,
};

const Wrapped = struct {
    did: []const u8,
    publisher: Publisher,
    curator: Curator,
    reader: Reader,
};

pub fn fetch(alloc: Allocator, did: []const u8) ![]const u8 {
    const local = db.getLocalDb() orelse return error.NotInitialized;

    // ---- publisher lens -------------------------------------------------
    var pub_count: i64 = 0;
    var total_subs: i64 = 0;
    {
        var rows = try local.query(
            \\SELECT COUNT(DISTINCT p.uri), COUNT(DISTINCT s.did)
            \\FROM publications p
            \\LEFT JOIN subscriptions s ON s.publication_uri = p.uri
            \\WHERE p.did = ?
        , .{did});
        defer rows.deinit();
        if (rows.next()) |row| {
            pub_count = row.int(0);
            total_subs = row.int(1);
        }
        if (rows.err()) |e| return e;
    }

    var owner_rank: ?i64 = null;
    var total_owners: i64 = 0;
    if (pub_count > 0) {
        {
            var rows = try local.query(
                \\SELECT COUNT(*) FROM (
                \\  SELECT p.did
                \\  FROM subscriptions s JOIN publications p ON p.uri = s.publication_uri
                \\  GROUP BY p.did
                \\)
            , .{});
            defer rows.deinit();
            if (rows.next()) |row| total_owners = row.int(0);
            if (rows.err()) |e| return e;
        }
        if (total_subs > 0) {
            var rows = try local.query(
                \\SELECT COUNT(*) + 1 FROM (
                \\  SELECT p.did AS owner, COUNT(DISTINCT s.did) AS subs
                \\  FROM subscriptions s JOIN publications p ON p.uri = s.publication_uri
                \\  GROUP BY p.did
                \\) t
                \\WHERE t.subs > (
                \\  SELECT COUNT(DISTINCT s2.did)
                \\  FROM subscriptions s2 JOIN publications p2 ON p2.uri = s2.publication_uri
                \\  WHERE p2.did = ?
                \\)
            , .{did});
            defer rows.deinit();
            if (rows.next()) |row| owner_rank = row.int(0);
            if (rows.err()) |e| return e;
        }
    }

    var top_pub: ?TopPub = null;
    if (pub_count > 0) {
        var rows = try local.query(
            \\SELECT p.uri, COALESCE(p.name, ''), COALESCE(p.base_path, ''),
            \\  COUNT(DISTINCT s.did) AS subs
            \\FROM publications p JOIN subscriptions s ON s.publication_uri = p.uri
            \\WHERE p.did = ?
            \\GROUP BY p.uri
            \\ORDER BY subs DESC, p.name
            \\LIMIT 1
        , .{did});
        defer rows.deinit();
        if (rows.next()) |row| {
            top_pub = .{
                .uri = try alloc.dupe(u8, row.text(0)),
                .name = try alloc.dupe(u8, row.text(1)),
                .basePath = try alloc.dupe(u8, row.text(2)),
                .subscribers = row.int(3),
            };
        }
        if (rows.err()) |e| return e;
    }

    // ---- curator lens ---------------------------------------------------
    var total_recommends: i64 = 0;
    var unique_docs: i64 = 0;
    var cur_first: []const u8 = "";
    var cur_last: []const u8 = "";
    {
        var rows = try local.query(
            \\SELECT COUNT(DISTINCT uri), COUNT(DISTINCT document_uri),
            \\  COALESCE(MIN(COALESCE(NULLIF(created_at, ''), indexed_at)), ''),
            \\  COALESCE(MAX(COALESCE(NULLIF(created_at, ''), indexed_at)), '')
            \\FROM recommends WHERE did = ?
        , .{did});
        defer rows.deinit();
        if (rows.next()) |row| {
            total_recommends = row.int(0);
            unique_docs = row.int(1);
            cur_first = try alloc.dupe(u8, row.text(2));
            cur_last = try alloc.dupe(u8, row.text(3));
        }
        if (rows.err()) |e| return e;
    }

    var cur_rank: ?i64 = null;
    var total_curators: i64 = 0;
    {
        var rows = try local.query("SELECT COUNT(DISTINCT did) FROM recommends", .{});
        defer rows.deinit();
        if (rows.next()) |row| total_curators = row.int(0);
        if (rows.err()) |e| return e;
    }
    if (total_recommends > 0) {
        var rows = try local.query(
            \\SELECT COUNT(*) + 1 FROM (
            \\  SELECT did, COUNT(DISTINCT uri) AS rc FROM recommends GROUP BY did
            \\) t
            \\WHERE t.rc > (SELECT COUNT(DISTINCT uri) FROM recommends WHERE did = ?)
        , .{did});
        defer rows.deinit();
        if (rows.next()) |row| cur_rank = row.int(0);
        if (rows.err()) |e| return e;
    }

    // ---- reader lens ----------------------------------------------------
    var sub_count: i64 = 0;
    var read_first: []const u8 = "";
    {
        // join publications so the count matches the `following` list exactly —
        // a subscription to a publication we don't index would otherwise inflate
        // the count past what we can render.
        var rows = try local.query(
            \\SELECT COUNT(DISTINCT s.publication_uri),
            \\  COALESCE(MIN(COALESCE(NULLIF(s.created_at, ''), s.indexed_at)), '')
            \\FROM subscriptions s JOIN publications p ON p.uri = s.publication_uri
            \\WHERE s.did = ?
        , .{did});
        defer rows.deinit();
        if (rows.next()) |row| {
            sub_count = row.int(0);
            read_first = try alloc.dupe(u8, row.text(1));
        }
        if (rows.err()) |e| return e;
    }

    var follows: std.ArrayList(Follow) = .empty;
    {
        var rows = try local.query(
            \\SELECT p.uri, p.did, COALESCE(p.name, ''), COALESCE(p.base_path, '')
            \\FROM subscriptions s JOIN publications p ON p.uri = s.publication_uri
            \\WHERE s.did = ?
            \\GROUP BY p.uri
            \\ORDER BY MAX(COALESCE(NULLIF(s.created_at, ''), s.indexed_at)) DESC
            \\LIMIT 12
        , .{did});
        defer rows.deinit();
        while (rows.next()) |row| {
            try follows.append(alloc, .{
                .uri = try alloc.dupe(u8, row.text(0)),
                .ownerDid = try alloc.dupe(u8, row.text(1)),
                .name = try alloc.dupe(u8, row.text(2)),
                .basePath = try alloc.dupe(u8, row.text(3)),
            });
        }
        if (rows.err()) |e| return e;
    }

    // ---- serialize ------------------------------------------------------
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.write(Wrapped{
        .did = did,
        .publisher = .{
            .pubCount = pub_count,
            .totalSubscribers = total_subs,
            .rank = owner_rank,
            .totalOwners = total_owners,
            .topPublication = top_pub,
        },
        .curator = .{
            .totalRecommends = total_recommends,
            .uniqueDocs = unique_docs,
            .rank = cur_rank,
            .totalCurators = total_curators,
            .firstAt = cur_first,
            .lastAt = cur_last,
        },
        .reader = .{
            .subscriptionCount = sub_count,
            .firstAt = read_first,
            .following = follows.items,
        },
    });
    return try output.toOwnedSlice();
}
