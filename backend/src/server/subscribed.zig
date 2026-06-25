//! /subscribed — leaderboards of the subscription signal.
//!
//! Sibling of /recommended one grain up: a recommend endorses one document,
//! a `site.standard.graph.subscription` follows a whole publication. Two views
//! over the same signal so they co-exist sensibly:
//!   - `publications`: which publications have the most subscribers.
//!   - `people`:       which authors have the most subscribers, summed across
//!                     all the publications they own (a subscriber to two of
//!                     someone's pubs counts once).
//!
//! Counts use COUNT(DISTINCT did) so each subscriber is counted once.
//! `subscriber_count` is windowed (drives rank); `total_count` is all-time
//! (displayed). Both equal for the `.all` window.
//!
//! Same caching shape as /recommended: a WindowedJsonCache(Window) per view
//! keeps the slow Turso GROUP BY off the hot path. No leaflet variant — the
//! subscription lexicon is standard.site-only by design (see tap.zig).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;
const zql = @import("zql");

const db = @import("../db.zig");
const recommended = @import("recommended.zig");
const cache = @import("cache.zig");
const pubkey = @import("pubkey.zig");

/// Reuse the Window enum from /recommended so the cache slot shape + URL
/// semantics (`since=day|week|month|year|all`) match across both pages.
pub const Window = recommended.Window;

pub const View = enum {
    publications,
    people,

    pub fn fromString(s: ?[]const u8) View {
        const str = s orelse return .publications;
        if (std.mem.eql(u8, str, "people")) return .people;
        return .publications;
    }

    pub fn slug(self: View) []const u8 {
        return @tagName(self);
    }
};

// publications view: rank publications by distinct subscribers. Pre-aggregate
// the small `subscriptions` table in a subquery, then look up each matched
// publication by PK — same shape (and same reason) as recommended.zig's
// TopQuery, which drives the scan from the small side instead of scanning the
// whole publications table. Subquery-in-FROM rather than CTE for the same
// zql comptime-parser reason documented there.
// Collection-agnostic: a publication dual-written under both lexicons (same
// did+rkey) is one row in `publications`; subscriptions may point at either
// at-uri. We join subscriptions → publications by (did, rkey) and GROUP BY
// p.uri so both collection uris collapse onto the single publication instead of
// splitting its subscribers across two leaderboard rows. Drives from the small
// subscriptions table; the (did, rkey) lookup is indexed (UNIQUE constraint).
const PublicationsQuery = zql.Query(
    \\SELECT p.uri, p.did AS owner_did,
    \\  COALESCE(p.name, '') AS name,
    \\  COALESCE(p.base_path, '') AS base_path,
    \\  COALESCE(p.platform, '') AS platform,
    \\  COUNT(DISTINCT CASE
    \\    WHEN DATE(COALESCE(NULLIF(s.created_at, ''), s.indexed_at)) >= DATE('now', ?)
    \\    THEN s.did END) AS subscriber_count,
    \\  COUNT(DISTINCT s.did) AS total_count
    \\FROM subscriptions s
    \\JOIN publications p ON
++ " " ++ pubkey.joinOn("p", "s.publication_uri") ++ "\n" ++
    \\GROUP BY p.uri
    \\HAVING subscriber_count > 0
    \\ORDER BY subscriber_count DESC, p.name
    \\LIMIT 250
);

// people view: rank publication OWNERS by distinct subscribers across all
// their publications. The DISTINCT s.did over the GROUP BY p.did collapses a
// subscriber who follows two of the same owner's pubs to one. `pub_count`
// surfaces how many distinct publications they own that have any subscribers.
const PeopleQuery = zql.Query(
    \\SELECT p.did AS owner_did,
    \\  COUNT(DISTINCT CASE
    \\    WHEN DATE(COALESCE(NULLIF(s.created_at, ''), s.indexed_at)) >= DATE('now', ?)
    \\    THEN s.did END) AS subscriber_count,
    \\  COUNT(DISTINCT s.did) AS total_count,
    \\  COUNT(DISTINCT p.uri) AS pub_count
    \\FROM subscriptions s
    \\JOIN publications p ON
++ " " ++ pubkey.joinOn("p", "s.publication_uri") ++ "\n" ++
    \\GROUP BY p.did
    \\HAVING subscriber_count > 0
    \\ORDER BY subscriber_count DESC, total_count DESC
    \\LIMIT 250
);

const PubRow = struct {
    uri: []const u8,
    owner_did: []const u8,
    name: []const u8,
    base_path: []const u8,
    platform: []const u8,
    subscriber_count: i64,
    total_count: i64,
};

const PubJsonRow = struct {
    type: []const u8 = "publication",
    uri: []const u8,
    ownerDid: []const u8,
    name: []const u8,
    basePath: []const u8,
    platform: []const u8,
    /// `https://<base_path>` for the publication's own site, or "" if unknown.
    url: []const u8,
    /// distinct subscribers WITHIN the chosen window (drives rank).
    subscriberCount: i64,
    /// distinct subscribers ALL-TIME (shown next to the rank).
    totalCount: i64,
};

const PeopleRow = struct {
    owner_did: []const u8,
    subscriber_count: i64,
    total_count: i64,
    pub_count: i64,
};

const PeopleJsonRow = struct {
    type: []const u8 = "person",
    did: []const u8,
    subscriberCount: i64,
    totalCount: i64,
    /// distinct publications this person owns that have any subscribers.
    pubCount: i64,
};

/// Fetch the top-250 leaderboard for (view, window) from Turso. Used by the
/// cache refresh thread and the cold-fallback path in the handler.
pub fn fetch(alloc: Allocator, view: View, window: Window) ![]const u8 {
    const c = db.getClient() orelse return error.NotInitialized;

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    const date_mod = window.dateModifier();

    switch (view) {
        .publications => {
            var res = c.query(PublicationsQuery.positional, &.{date_mod}) catch {
                try output.writer.writeAll("{\"error\":\"failed to fetch subscribed publications\"}");
                return try output.toOwnedSlice();
            };
            defer res.deinit();

            var jw: json.Stringify = .{ .writer = &output.writer };
            try jw.beginArray();
            for (res.rows) |row| {
                const r = PublicationsQuery.fromRow(PubRow, row);
                const url = if (r.base_path.len > 0)
                    try std.fmt.allocPrint(alloc, "https://{s}", .{r.base_path})
                else
                    "";
                try jw.write(PubJsonRow{
                    .uri = r.uri,
                    .ownerDid = r.owner_did,
                    .name = r.name,
                    .basePath = r.base_path,
                    .platform = r.platform,
                    .url = url,
                    .subscriberCount = r.subscriber_count,
                    .totalCount = r.total_count,
                });
            }
            try jw.endArray();
        },
        .people => {
            var res = c.query(PeopleQuery.positional, &.{date_mod}) catch {
                try output.writer.writeAll("{\"error\":\"failed to fetch subscribed people\"}");
                return try output.toOwnedSlice();
            };
            defer res.deinit();

            var jw: json.Stringify = .{ .writer = &output.writer };
            try jw.beginArray();
            for (res.rows) |row| {
                const r = PeopleQuery.fromRow(PeopleRow, row);
                try jw.write(PeopleJsonRow{
                    .did = r.owner_did,
                    .subscriberCount = r.subscriber_count,
                    .totalCount = r.total_count,
                    .pubCount = r.pub_count,
                });
            }
            try jw.endArray();
        },
    }

    return try output.toOwnedSlice();
}

fn refreshPublications(slot: Window, alloc: Allocator) anyerror![]const u8 {
    return fetch(alloc, .publications, slot);
}

fn refreshPeople(slot: Window, alloc: Allocator) anyerror![]const u8 {
    return fetch(alloc, .people, slot);
}

/// One cache per view, each storing 5 window slots — same pattern as
/// recommended's top/trending caches.
pub const PublicationsCache = cache.WindowedJsonCache(Window, .{
    .name = "subscribed.publications",
    .refresh = &refreshPublications,
});
pub const PeopleCache = cache.WindowedJsonCache(Window, .{
    .name = "subscribed.people",
    .refresh = &refreshPeople,
});

pub fn snapshot(view: View, window: Window, alloc: Allocator) !?[]u8 {
    return switch (view) {
        .publications => PublicationsCache.snapshot(window, alloc),
        .people => PeopleCache.snapshot(window, alloc),
    };
}

pub fn init(io: Io) void {
    PublicationsCache.init(io);
    PeopleCache.init(io);
}

/// Reuse recommended.sliceJson — structure-agnostic pagination over a cached
/// top-N JSON array.
pub const sliceJson = recommended.sliceJson;
