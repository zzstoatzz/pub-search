const std = @import("std");
const mem = std.mem;

/// decentralized identifier - did:plc:xxx or did:web:xxx
pub const Did = struct {
    raw: []const u8,

    pub fn parse(s: []const u8) ?Did {
        if (!mem.startsWith(u8, s, "did:")) return null;
        const rest = s[4..];
        // must have method:identifier
        const colon = mem.indexOf(u8, rest, ":") orelse return null;
        if (colon == 0 or colon == rest.len - 1) return null;
        return .{ .raw = s };
    }

    pub fn format(self: Did, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll(self.raw);
    }

    pub fn eql(self: Did, other: Did) bool {
        return mem.eql(u8, self.raw, other.raw);
    }

    pub fn str(self: Did) []const u8 {
        return self.raw;
    }
};

/// at-uri - at://did/collection/rkey
pub const AtUri = struct {
    raw: []const u8,
    did_end: usize,
    collection_end: usize,

    pub fn parse(s: []const u8) ?AtUri {
        if (!mem.startsWith(u8, s, "at://")) return null;
        const rest = s[5..];

        // find did end (first slash after did)
        const did_end = mem.indexOf(u8, rest, "/") orelse return null;
        if (did_end == 0) return null;

        // validate did portion
        const did_str = rest[0..did_end];
        if (Did.parse(did_str) == null) return null;

        // find collection end (second slash)
        const after_did = rest[did_end + 1 ..];
        const collection_end = mem.indexOf(u8, after_did, "/") orelse return null;
        if (collection_end == 0) return null;

        // rkey must exist
        const rkey_part = after_did[collection_end + 1 ..];
        if (rkey_part.len == 0) return null;

        return .{
            .raw = s,
            .did_end = 5 + did_end,
            .collection_end = 5 + did_end + 1 + collection_end,
        };
    }

    pub fn build(allocator: mem.Allocator, d: Did, coll: []const u8, rk: []const u8) !AtUri {
        const raw = try std.fmt.allocPrint(allocator, "at://{s}/{s}/{s}", .{ d.raw, coll, rk });
        return .{
            .raw = raw,
            .did_end = 5 + d.raw.len,
            .collection_end = 5 + d.raw.len + 1 + coll.len,
        };
    }

    pub fn did(self: AtUri) Did {
        return .{ .raw = self.raw[5..self.did_end] };
    }

    pub fn collection(self: AtUri) []const u8 {
        return self.raw[self.did_end + 1 .. self.collection_end];
    }

    pub fn rkey(self: AtUri) []const u8 {
        return self.raw[self.collection_end + 1 ..];
    }

    pub fn format(self: AtUri, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll(self.raw);
    }

    pub fn str(self: AtUri) []const u8 {
        return self.raw;
    }
};

test "Did.parse valid" {
    const d = Did.parse("did:plc:abc123").?;
    try std.testing.expectEqualStrings("did:plc:abc123", d.raw);
}

test "Did.parse invalid" {
    try std.testing.expect(Did.parse("notadid") == null);
    try std.testing.expect(Did.parse("did:") == null);
    try std.testing.expect(Did.parse("did:plc") == null);
    try std.testing.expect(Did.parse("did::abc") == null);
}

test "AtUri.parse valid" {
    const u = AtUri.parse("at://did:plc:abc/app.bsky.post/123").?;
    try std.testing.expectEqualStrings("did:plc:abc", u.did().raw);
    try std.testing.expectEqualStrings("app.bsky.post", u.collection());
    try std.testing.expectEqualStrings("123", u.rkey());
}

test "AtUri.parse invalid" {
    try std.testing.expect(AtUri.parse("https://example.com") == null);
    try std.testing.expect(AtUri.parse("at://") == null);
    try std.testing.expect(AtUri.parse("at://did:plc:abc") == null);
    try std.testing.expect(AtUri.parse("at://did:plc:abc/collection") == null);
    try std.testing.expect(AtUri.parse("at://did:plc:abc/collection/") == null);
}

test "AtUri.build" {
    const d = Did.parse("did:plc:xyz").?;
    const u = try AtUri.build(std.testing.allocator, d, "pub.leaflet.document", "abc");
    defer std.testing.allocator.free(u.raw);
    try std.testing.expectEqualStrings("at://did:plc:xyz/pub.leaflet.document/abc", u.raw);
    try std.testing.expectEqualStrings("did:plc:xyz", u.did().raw);
    try std.testing.expectEqualStrings("pub.leaflet.document", u.collection());
    try std.testing.expectEqualStrings("abc", u.rkey());
}
