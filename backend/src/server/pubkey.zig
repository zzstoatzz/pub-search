//! Collection-agnostic subscription→publication matching.
//!
//! Leaflet dual-writes each publication under BOTH `pub.leaflet.publication`
//! and `site.standard.publication` with the SAME rkey, but `publications` has a
//! UNIQUE(did, rkey) constraint, so only ONE of the two at-uris is ever stored.
//! A `site.standard.graph.subscription` record may reference EITHER collection's
//! at-uri, so an exact `p.uri = s.publication_uri` join silently misses every
//! subscription that points at the other collection (~25% of distinct pubs,
//! measured 2026-06-25).
//!
//! We instead match on the (did, rkey) decoded from the subscription's
//! `publication_uri` — both collection uris share the same did and rkey. Pure
//! read-side SQL; no schema change, so reverting is just reverting the queries.
//!
//! Decodes "at://<did>/<collection>/<rkey>" with only substr/instr — no length
//! assumptions on the rkey. `<uri_col>` must be a column expression holding an
//! at-uri (e.g. "s.publication_uri").

const std = @import("std");

pub const Parsed = struct { did: []const u8, rkey: []const u8 };

/// Decode an at-uri "at://<did>/<collection>/<rkey>" into its did + rkey, or
/// null if malformed. The Zig-side twin of didExpr/rkeyExpr, for queries that
/// bind the parts as params instead of matching against a uri column.
pub fn parse(uri: []const u8) ?Parsed {
    if (!std.mem.startsWith(u8, uri, "at://")) return null;
    const rest = uri["at://".len..];
    const slash1 = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const did = rest[0..slash1];
    const after = rest[slash1 + 1 ..];
    const last_slash = std.mem.lastIndexOfScalar(u8, after, '/') orelse return null;
    const rkey = after[last_slash + 1 ..];
    if (did.len == 0 or rkey.len == 0) return null;
    return .{ .did = did, .rkey = rkey };
}

/// SQL expression yielding the owner DID embedded in `<uri_col>`.
pub fn didExpr(comptime uri_col: []const u8) []const u8 {
    const rest = "substr(" ++ uri_col ++ ", 6)"; // strip "at://"
    return "substr(" ++ uri_col ++ ", 6, instr(" ++ rest ++ ", '/') - 1)";
}

/// SQL expression yielding the rkey (last path segment) of `<uri_col>`.
pub fn rkeyExpr(comptime uri_col: []const u8) []const u8 {
    const rest = "substr(" ++ uri_col ++ ", 6)"; // "<did>/<collection>/<rkey>"
    const cr = "substr(" ++ rest ++ ", instr(" ++ rest ++ ", '/') + 1)"; // "<collection>/<rkey>"
    return "substr(" ++ cr ++ ", instr(" ++ cr ++ ", '/') + 1)";
}

/// SQL `ON` predicate matching publication alias `<pub>` to the at-uri in
/// `<uri_col>` by (did, rkey) — collection-agnostic, by PARSING the uri per row.
/// Non-sargable: the parse defeats any index on the uri side, so the join
/// full-scans. Kept only for callers without the materialized columns; prefer
/// `joinOnStored` against tables that carry `publication_did/_rkey`.
pub fn joinOn(comptime pub_alias: []const u8, comptime uri_col: []const u8) []const u8 {
    return pub_alias ++ ".did = " ++ didExpr(uri_col) ++
        " AND " ++ pub_alias ++ ".rkey = " ++ rkeyExpr(uri_col);
}

/// SQL `ON` predicate matching publication alias `<pub>` to a subscriptions
/// (or recommends) alias `<sub>` via the MATERIALIZED `publication_did` /
/// `publication_rkey` columns — a sargable indexed equijoin. This is the same
/// (did, rkey) `joinOn` computes at read time, but parsed once at write/build
/// time and indexed (idx_subscriptions_pub_did_rkey), so a publisher with 621
/// publications does index seeks instead of full-scanning 8923 subscriptions
/// per publication (45s → 0.39s at 16-way, measured).
pub fn joinOnStored(comptime pub_alias: []const u8, comptime sub_alias: []const u8) []const u8 {
    return pub_alias ++ ".did = " ++ sub_alias ++ ".publication_did" ++
        " AND " ++ pub_alias ++ ".rkey = " ++ sub_alias ++ ".publication_rkey";
}

test "parse decodes did + rkey from an at-uri" {
    const p = parse("at://did:plc:25z6ogppprfvijcnqo2fsfce/pub.leaflet.publication/3lxbg6eithc2v").?;
    try std.testing.expectEqualStrings("did:plc:25z6ogppprfvijcnqo2fsfce", p.did);
    try std.testing.expectEqualStrings("3lxbg6eithc2v", p.rkey);
    // same did+rkey under the other collection — the whole point of the fix.
    const q = parse("at://did:plc:25z6ogppprfvijcnqo2fsfce/site.standard.publication/3lxbg6eithc2v").?;
    try std.testing.expectEqualStrings(p.did, q.did);
    try std.testing.expectEqualStrings(p.rkey, q.rkey);
}

test "parse rejects malformed uris" {
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("https://example.com") == null);
    try std.testing.expect(parse("at://did:plc:abc") == null); // no collection/rkey
    try std.testing.expect(parse("at:///pub.leaflet.publication/3abc") == null); // empty did
}

test "didExpr / rkeyExpr build the expected SQL" {
    try std.testing.expectEqualStrings(
        "substr(s.publication_uri, 6, instr(substr(s.publication_uri, 6), '/') - 1)",
        didExpr("s.publication_uri"),
    );
    try std.testing.expectEqualStrings(
        "substr(substr(substr(s.publication_uri, 6), instr(substr(s.publication_uri, 6), '/') + 1)," ++
            " instr(substr(substr(s.publication_uri, 6), instr(substr(s.publication_uri, 6), '/') + 1), '/') + 1)",
        rkeyExpr("s.publication_uri"),
    );
}
