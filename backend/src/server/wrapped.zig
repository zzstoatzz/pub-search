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
const pubkey = @import("pubkey.zig");

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
    /// host (base_path) of every publication they own — lets the frontend
    /// light up their footprint in the atlas backdrop.
    publications: []const []const u8,
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

const PlatformCount = struct { platform: []const u8, count: i64 };
const TagCount = struct { tag: []const u8, count: i64 };
const MonthCount = struct { month: []const u8, count: i64 };

const Author = struct {
    /// documents this DID has written that we index.
    totalPosts: i64,
    /// first / most-recent post (ISO 8601; empty when none).
    firstAt: []const u8,
    lastAt: []const u8,
    /// how many of their posts live inside a publication (vs standalone looseleaf).
    inPublication: i64,
    /// how many carry a cover image.
    withCover: i64,
    /// space-split word-count approximation, summed and maxed over their posts.
    totalWords: i64,
    longestWords: i64,
    /// posts per platform, most-published first.
    platforms: []const PlatformCount,
    /// their most-used tags (topics), most-used first.
    tags: []const TagCount,
    /// posts per calendar month (YYYY-MM), chronological — drives the cadence
    /// sparkline + "most active month".
    months: []const MonthCount,
};

const Wrapped = struct {
    did: []const u8,
    author: Author,
    publisher: Publisher,
    curator: Curator,
    reader: Reader,
};

pub fn fetch(alloc: Allocator, did: []const u8) ![]const u8 {
    const local = db.getLocalDb() orelse return error.NotInitialized;

    // ---- author lens (their actual writing) -----------------------------
    // word count is a space-split approximation: spaces + 1 per non-empty post.
    var author_total: i64 = 0;
    var author_first: []const u8 = "";
    var author_last: []const u8 = "";
    var author_in_pub: i64 = 0;
    var author_with_cover: i64 = 0;
    var author_total_words: i64 = 0;
    var author_longest_words: i64 = 0;
    {
        var rows = try local.query(
            \\SELECT COUNT(*),
            \\  COALESCE(MIN(NULLIF(created_at, '')), ''),
            \\  COALESCE(MAX(NULLIF(created_at, '')), ''),
            \\  COALESCE(SUM(has_publication), 0),
            \\  COALESCE(SUM(CASE WHEN cover_image IS NOT NULL AND cover_image <> '' THEN 1 ELSE 0 END), 0),
            \\  COALESCE(SUM(CASE WHEN content <> '' THEN LENGTH(content) - LENGTH(REPLACE(content, ' ', '')) + 1 ELSE 0 END), 0),
            \\  COALESCE(MAX(CASE WHEN content <> '' THEN LENGTH(content) - LENGTH(REPLACE(content, ' ', '')) + 1 ELSE 0 END), 0)
            \\FROM documents WHERE did = ?
        , .{did});
        defer rows.deinit();
        if (rows.next()) |row| {
            author_total = row.int(0);
            author_first = try alloc.dupe(u8, row.text(1));
            author_last = try alloc.dupe(u8, row.text(2));
            author_in_pub = row.int(3);
            author_with_cover = row.int(4);
            author_total_words = row.int(5);
            author_longest_words = row.int(6);
        }
        if (rows.err()) |e| return e;
    }

    var platforms: std.ArrayList(PlatformCount) = .empty;
    if (author_total > 0) {
        var rows = try local.query(
            \\SELECT COALESCE(NULLIF(platform, ''), 'other'), COUNT(*)
            \\FROM documents WHERE did = ?
            \\GROUP BY 1 ORDER BY 2 DESC, 1
        , .{did});
        defer rows.deinit();
        while (rows.next()) |row| {
            try platforms.append(alloc, .{
                .platform = try alloc.dupe(u8, row.text(0)),
                .count = row.int(1),
            });
        }
        if (rows.err()) |e| return e;
    }

    var author_tags: std.ArrayList(TagCount) = .empty;
    if (author_total > 0) {
        var rows = try local.query(
            \\SELECT t.tag, COUNT(*) AS n
            \\FROM document_tags t JOIN documents d ON d.uri = t.document_uri
            \\WHERE d.did = ?
            \\GROUP BY t.tag ORDER BY n DESC, t.tag
            \\LIMIT 12
        , .{did});
        defer rows.deinit();
        while (rows.next()) |row| {
            try author_tags.append(alloc, .{
                .tag = try alloc.dupe(u8, row.text(0)),
                .count = row.int(1),
            });
        }
        if (rows.err()) |e| return e;
    }

    var months: std.ArrayList(MonthCount) = .empty;
    if (author_total > 0) {
        var rows = try local.query(
            \\SELECT substr(created_at, 1, 7) AS ym, COUNT(*)
            \\FROM documents WHERE did = ? AND created_at <> ''
            \\GROUP BY ym ORDER BY ym
            \\LIMIT 60
        , .{did});
        defer rows.deinit();
        while (rows.next()) |row| {
            try months.append(alloc, .{
                .month = try alloc.dupe(u8, row.text(0)),
                .count = row.int(1),
            });
        }
        if (rows.err()) |e| return e;
    }

    // ---- publisher lens -------------------------------------------------
    var pub_count: i64 = 0;
    var total_subs: i64 = 0;
    {
        var rows = try local.query(
            \\SELECT COUNT(DISTINCT p.uri), COUNT(DISTINCT s.did)
            \\FROM publications p
            \\LEFT JOIN subscriptions s ON
        ++ " " ++ pubkey.joinOnStored("p", "s") ++ "\n" ++
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
                \\  FROM subscriptions s JOIN publications p ON
            ++ " " ++ pubkey.joinOnStored("p", "s") ++ "\n" ++
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
                \\  FROM subscriptions s JOIN publications p ON
            ++ " " ++ pubkey.joinOnStored("p", "s") ++ "\n" ++
                \\  GROUP BY p.did
                \\) t
                \\WHERE t.subs > (
                \\  SELECT COUNT(DISTINCT s2.did)
                \\  FROM subscriptions s2 JOIN publications p2 ON
            ++ " " ++ pubkey.joinOnStored("p2", "s2") ++ "\n" ++
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
            \\FROM publications p JOIN subscriptions s ON
        ++ " " ++ pubkey.joinOnStored("p", "s") ++ "\n" ++
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

    var pub_hosts: std.ArrayList([]const u8) = .empty;
    if (pub_count > 0) {
        var rows = try local.query(
            \\SELECT DISTINCT base_path FROM publications
            \\WHERE did = ? AND base_path IS NOT NULL AND base_path <> ''
            \\ORDER BY base_path LIMIT 32
        , .{did});
        defer rows.deinit();
        while (rows.next()) |row| {
            try pub_hosts.append(alloc, try alloc.dupe(u8, row.text(0)));
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
        // the count. COUNT(DISTINCT p.uri) (not s.publication_uri) so a reader who
        // subscribed under BOTH dual-write collection uris still counts the
        // publication once, matching the GROUP BY p.uri following list below.
        var rows = try local.query(
            \\SELECT COUNT(DISTINCT p.uri),
            \\  COALESCE(MIN(COALESCE(NULLIF(s.created_at, ''), s.indexed_at)), '')
            \\FROM subscriptions s JOIN publications p ON
        ++ " " ++ pubkey.joinOnStored("p", "s") ++ "\n" ++
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
            \\FROM subscriptions s JOIN publications p ON
        ++ " " ++ pubkey.joinOnStored("p", "s") ++ "\n" ++
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
        .author = .{
            .totalPosts = author_total,
            .firstAt = author_first,
            .lastAt = author_last,
            .inPublication = author_in_pub,
            .withCover = author_with_cover,
            .totalWords = author_total_words,
            .longestWords = author_longest_words,
            .platforms = platforms.items,
            .tags = author_tags.items,
            .months = months.items,
        },
        .publisher = .{
            .pubCount = pub_count,
            .totalSubscribers = total_subs,
            .rank = owner_rank,
            .totalOwners = total_owners,
            .topPublication = top_pub,
            .publications = pub_hosts.items,
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
