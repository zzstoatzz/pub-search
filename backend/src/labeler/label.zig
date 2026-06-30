//! AT Protocol label type with CBOR encoding and signing
//!
//! implements com.atproto.label.defs#label:
//!   encode label (sans sig) as deterministic DAG-CBOR,
//!   ECDSA sign (scheme handles SHA-256 internally), attach sig bytes.

const std = @import("std");
const zat = @import("zat");
const cbor = zat.cbor;
const Keypair = zat.Keypair;

const Allocator = std.mem.Allocator;

pub const Label = struct {
    ver: u8 = 1,
    src: []const u8, // labeler DID
    uri: []const u8, // subject (at:// URI or DID)
    cid: ?[]const u8 = null, // optional, pins to record version
    val: []const u8, // label value (max 128 bytes)
    neg: bool = false, // negates previous label
    cts: []const u8, // created-at ISO 8601
    exp: ?[]const u8 = null, // optional expiration
    sig: ?[]const u8 = null, // filled after signing

    /// encode the label (without sig) as deterministic DAG-CBOR.
    /// caller owns the returned slice.
    pub fn encodeUnsigned(self: *const Label, allocator: Allocator) ![]u8 {
        var entries: [9]cbor.Value.MapEntry = undefined;
        const n = self.fillEntries(&entries, false);
        return cbor.encodeAlloc(allocator, .{ .map = entries[0..n] });
    }

    /// sign this label: CBOR-encode (sans sig) → ECDSA sign (scheme hashes internally).
    /// returns the raw signature bytes (64 bytes, r||s).
    /// does NOT mutate self — caller should set self.sig.
    pub fn computeSignature(self: *const Label, allocator: Allocator, keypair: *const Keypair) !zat.jwt.Signature {
        const unsigned_bytes = try self.encodeUnsigned(allocator);
        defer allocator.free(unsigned_bytes);

        return keypair.sign(unsigned_bytes);
    }

    /// encode the full label (with sig) as deterministic DAG-CBOR.
    /// self.sig must be set before calling this.
    pub fn encodeSigned(self: *const Label, allocator: Allocator) ![]u8 {
        std.debug.assert(self.sig != null);
        var entries: [9]cbor.Value.MapEntry = undefined;
        const n = self.fillEntries(&entries, true);
        return cbor.encodeAlloc(allocator, .{ .map = entries[0..n] });
    }

    /// sign and return a fully-encoded signed label.
    /// sets self.sig as a side effect.
    pub fn signAndEncode(self: *Label, allocator: Allocator, keypair: *const Keypair, sig_buf: *[64]u8) ![]u8 {
        const sig = try self.computeSignature(allocator, keypair);
        sig_buf.* = sig.bytes;
        self.sig = sig_buf;
        return self.encodeSigned(allocator);
    }

    /// fill entries buffer with CBOR map entries. returns number of entries written.
    /// entries buffer must be at least 9 elements. the returned slice is valid
    /// as long as the buffer and self are alive.
    fn fillEntries(self: *const Label, entries: *[9]cbor.Value.MapEntry, include_sig: bool) usize {
        var i: usize = 0;

        if (self.cid) |ci| {
            entries[i] = .{ .key = "cid", .value = .{ .text = ci } };
            i += 1;
        }
        entries[i] = .{ .key = "cts", .value = .{ .text = self.cts } };
        i += 1;
        if (self.exp) |e| {
            entries[i] = .{ .key = "exp", .value = .{ .text = e } };
            i += 1;
        }
        if (self.neg) {
            entries[i] = .{ .key = "neg", .value = .{ .boolean = true } };
            i += 1;
        }
        if (include_sig) {
            if (self.sig) |s| {
                entries[i] = .{ .key = "sig", .value = .{ .bytes = s } };
                i += 1;
            }
        }
        entries[i] = .{ .key = "src", .value = .{ .text = self.src } };
        i += 1;
        entries[i] = .{ .key = "uri", .value = .{ .text = self.uri } };
        i += 1;
        entries[i] = .{ .key = "val", .value = .{ .text = self.val } };
        i += 1;
        entries[i] = .{ .key = "ver", .value = .{ .unsigned = self.ver } };
        i += 1;

        return i;
    }
};

/// encode an XRPC event stream frame: header CBOR || payload CBOR.
/// used for both subscribeLabels and firehose-style event streams.
pub fn encodeEventFrame(allocator: Allocator, op: i64, frame_type: ?[]const u8, payload: cbor.Value) ![]u8 {
    // header: {op: <int>, t?: <string>}
    var header_entries: [2]cbor.Value.MapEntry = undefined;
    var h_count: usize = 0;

    if (op >= 0) {
        header_entries[h_count] = .{ .key = "op", .value = .{ .unsigned = @intCast(op) } };
    } else {
        header_entries[h_count] = .{ .key = "op", .value = .{ .negative = op } };
    }
    h_count += 1;

    if (frame_type) |t| {
        header_entries[h_count] = .{ .key = "t", .value = .{ .text = t } };
        h_count += 1;
    }

    const header: cbor.Value = .{ .map = header_entries[0..h_count] };

    const header_bytes = try cbor.encodeAlloc(allocator, header);
    defer allocator.free(header_bytes);
    const payload_bytes = try cbor.encodeAlloc(allocator, payload);
    defer allocator.free(payload_bytes);

    const frame = try allocator.alloc(u8, header_bytes.len + payload_bytes.len);
    @memcpy(frame[0..header_bytes.len], header_bytes);
    @memcpy(frame[header_bytes.len..], payload_bytes);
    return frame;
}

// === tests ===

test "label unsigned CBOR round-trip" {
    const allocator = std.testing.allocator;

    const label = Label{
        .src = "did:plc:test123",
        .uri = "at://did:plc:user/app.bsky.feed.post/abc",
        .val = "spam",
        .cts = "2024-01-01T00:00:00.000Z",
    };

    const encoded = try label.encodeUnsigned(allocator);
    defer allocator.free(encoded);

    // decode and verify fields
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decoded = try cbor.decodeAll(arena.allocator(), encoded);

    try std.testing.expectEqualStrings("did:plc:test123", decoded.getString("src").?);
    try std.testing.expectEqualStrings("at://did:plc:user/app.bsky.feed.post/abc", decoded.getString("uri").?);
    try std.testing.expectEqualStrings("spam", decoded.getString("val").?);
    try std.testing.expectEqualStrings("2024-01-01T00:00:00.000Z", decoded.getString("cts").?);
    try std.testing.expectEqual(@as(u64, 1), decoded.getUint("ver").?);
    // neg=false should be omitted
    try std.testing.expect(decoded.get("neg") == null);
    // sig should be omitted in unsigned encoding
    try std.testing.expect(decoded.get("sig") == null);
}

test "label with optional fields" {
    const allocator = std.testing.allocator;

    const label = Label{
        .src = "did:plc:labeler",
        .uri = "did:plc:subject",
        .val = "!warn",
        .neg = true,
        .cts = "2024-06-15T12:00:00.000Z",
        .exp = "2025-06-15T12:00:00.000Z",
        .cid = "bafyreitest",
    };

    const encoded = try label.encodeUnsigned(allocator);
    defer allocator.free(encoded);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decoded = try cbor.decodeAll(arena.allocator(), encoded);

    try std.testing.expectEqual(true, decoded.getBool("neg").?);
    try std.testing.expectEqualStrings("2025-06-15T12:00:00.000Z", decoded.getString("exp").?);
    try std.testing.expectEqualStrings("bafyreitest", decoded.getString("cid").?);
}

test "label sign and verify" {
    const allocator = std.testing.allocator;

    const keypair = try Keypair.fromSecretKey(.secp256k1, .{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20,
    });

    var label = Label{
        .src = "did:plc:test",
        .uri = "at://did:plc:user/app.bsky.feed.post/abc",
        .val = "spam",
        .cts = "2024-01-01T00:00:00.000Z",
    };

    var sig_buf: [64]u8 = undefined;
    const encoded = try label.signAndEncode(allocator, &keypair, &sig_buf);
    defer allocator.free(encoded);

    // decode and check sig is present
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decoded = try cbor.decodeAll(arena.allocator(), encoded);
    const sig_bytes = decoded.getBytes("sig").?;
    try std.testing.expectEqual(@as(usize, 64), sig_bytes.len);

    // verify the signature: re-encode unsigned, verify (scheme hashes internally)
    const unsigned = try label.encodeUnsigned(allocator);
    defer allocator.free(unsigned);

    const pk = try keypair.publicKey();
    try zat.jwt.verifySecp256k1(unsigned, sig_bytes, &pk);
}

test "label deterministic encoding" {
    const allocator = std.testing.allocator;

    const label = Label{
        .src = "did:plc:test",
        .uri = "at://did:plc:user/app.bsky.feed.post/abc",
        .val = "spam",
        .cts = "2024-01-01T00:00:00.000Z",
    };

    const enc1 = try label.encodeUnsigned(allocator);
    defer allocator.free(enc1);
    const enc2 = try label.encodeUnsigned(allocator);
    defer allocator.free(enc2);

    try std.testing.expectEqualSlices(u8, enc1, enc2);
}

test "label DAG-CBOR key ordering" {
    const allocator = std.testing.allocator;

    // with all fields: keys should be sorted by length then lex
    // 3-char: cid, cts, exp, neg, sig, src, uri, val, ver
    // all same length (3) → sorted lex: cid, cts, exp, neg, sig, src, uri, val, ver
    const label = Label{
        .src = "did:plc:labeler",
        .uri = "did:plc:subject",
        .val = "test",
        .neg = true,
        .cts = "2024-01-01T00:00:00.000Z",
        .exp = "2025-01-01T00:00:00.000Z",
        .cid = "bafytest",
        .sig = &(.{0xaa} ** 64),
    };

    const encoded = try label.encodeSigned(allocator);
    defer allocator.free(encoded);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decoded = try cbor.decodeAll(arena.allocator(), encoded);

    // verify map key order
    const entries = decoded.map;
    try std.testing.expectEqualStrings("cid", entries[0].key);
    try std.testing.expectEqualStrings("cts", entries[1].key);
    try std.testing.expectEqualStrings("exp", entries[2].key);
    try std.testing.expectEqualStrings("neg", entries[3].key);
    try std.testing.expectEqualStrings("sig", entries[4].key);
    try std.testing.expectEqualStrings("src", entries[5].key);
    try std.testing.expectEqualStrings("uri", entries[6].key);
    try std.testing.expectEqualStrings("val", entries[7].key);
    try std.testing.expectEqualStrings("ver", entries[8].key);
}

test "encode event frame" {
    const allocator = std.testing.allocator;

    // simple labels frame: {op: 1, t: "#labels"} + {seq: 1, labels: [...]}
    const payload: cbor.Value = .{ .map = &.{
        .{ .key = "seq", .value = .{ .unsigned = 42 } },
    } };

    const frame = try encodeEventFrame(allocator, 1, "#labels", payload);
    defer allocator.free(frame);

    // decode header
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const header_result = try cbor.decode(alloc, frame);
    try std.testing.expectEqual(@as(u64, 1), header_result.value.getUint("op").?);
    try std.testing.expectEqualStrings("#labels", header_result.value.getString("t").?);

    // decode payload
    const payload_decoded = try cbor.decodeAll(alloc, frame[header_result.consumed..]);
    try std.testing.expectEqual(@as(u64, 42), payload_decoded.getUint("seq").?);
}

test "encode error frame" {
    const allocator = std.testing.allocator;

    const payload: cbor.Value = .{ .map = &.{
        .{ .key = "error", .value = .{ .text = "FutureCursor" } },
        .{ .key = "message", .value = .{ .text = "cursor is in the future" } },
    } };

    const frame = try encodeEventFrame(allocator, -1, null, payload);
    defer allocator.free(frame);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const header_result = try cbor.decode(alloc, frame);
    try std.testing.expectEqual(@as(i64, -1), header_result.value.getInt("op").?);
    try std.testing.expect(header_result.value.getString("t") == null);

    const payload_decoded = try cbor.decodeAll(alloc, frame[header_result.consumed..]);
    try std.testing.expectEqualStrings("FutureCursor", payload_decoded.getString("error").?);
}
