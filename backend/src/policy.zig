//! Corpus admission policy shared by every write path: the ingester drops
//! these at the firehose, the indexer drops them on insert (replays,
//! backfills), and the snapshot builder excludes them at build time —
//! turso may still hold historical rows for a banned DID until the paced
//! cleanup finishes, and a snapshot must never resurrect them.

const std = @import("std");

/// Bulk-archive repos that never enter the corpus (purged 2026-06-10).
pub const BANNED_DIDS = [_][]const u8{
    // registry of who/why/evidence: docs/exclusions.md — every entry here
    // must have one there. mirror changes into ingester/src/main.zig and
    // scripts/purge-banned-turso + purge-bridgyfed-vectors.
    "did:plc:oql6ds5vnff4ugar6rruliwd", // drivepatents.com patent bot
    "did:plc:2s32mlusc66sjb256aenynfc", // destinationcharged.com NHTSA recall mirror
    "did:plc:llnmp5t7s3u4dzjqyhp76h62", // crownnote.com music-charts mirror
};

pub fn isBanned(did: []const u8) bool {
    for (BANNED_DIDS) |banned| {
        if (std.mem.eql(u8, did, banned)) return true;
    }
    return false;
}

/// Comptime SQL fragment: `'did1','did2'` — for `did NOT IN (...)` clauses.
pub const banned_dids_sql = blk: {
    var out: []const u8 = "";
    for (BANNED_DIDS, 0..) |did, i| {
        out = out ++ (if (i == 0) "'" else ",'") ++ did ++ "'";
    }
    break :blk out;
};

test "isBanned matches only the banned list" {
    try std.testing.expect(isBanned("did:plc:oql6ds5vnff4ugar6rruliwd"));
    try std.testing.expect(isBanned("did:plc:2s32mlusc66sjb256aenynfc"));
    try std.testing.expect(isBanned("did:plc:llnmp5t7s3u4dzjqyhp76h62"));
    try std.testing.expect(!isBanned("did:plc:ragtjsm2j2vknwkz3zp4oxrd"));
}

test "banned_dids_sql is a quoted comma-separated list" {
    try std.testing.expectEqualStrings(
        "'did:plc:oql6ds5vnff4ugar6rruliwd','did:plc:2s32mlusc66sjb256aenynfc','did:plc:llnmp5t7s3u4dzjqyhp76h62'",
        banned_dids_sql,
    );
}
