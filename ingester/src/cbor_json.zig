//! Serialize a decoded DAG-CBOR value (zat.cbor.Value) to atproto's dag-json
//! form — the same JSON shape indigo `tap` emits, so the backend's extractor
//! parses our records identically. Conventions:
//!   CID   -> {"$link": "<base32 cidv1>"}   (consumed as e.g. coverImage.ref.$link)
//!   bytes -> {"$bytes": "<base64>"}
//! Everything else maps to the obvious JSON type.

const std = @import("std");
const zat = @import("zat");
const cbor = zat.cbor;

pub fn writeValue(writer: *std.Io.Writer, alloc: std.mem.Allocator, value: cbor.Value) !void {
    switch (value) {
        .text => |s| try writeJsonString(writer, s),
        .unsigned => |u| try writer.print("{d}", .{u}),
        .negative => |n| try writer.print("{d}", .{n}),
        .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
        .null => try writer.writeAll("null"),
        .array => |items| {
            try writer.writeByte('[');
            for (items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try writeValue(writer, alloc, item);
            }
            try writer.writeByte(']');
        },
        .map => |entries| {
            try writer.writeByte('{');
            for (entries, 0..) |entry, i| {
                if (i > 0) try writer.writeByte(',');
                try writeJsonString(writer, entry.key);
                try writer.writeByte(':');
                try writeValue(writer, alloc, entry.value);
            }
            try writer.writeByte('}');
        },
        .cid => |c| {
            // dag-json: {"$link": "<multibase base32 cidv1>"} — 'b' prefix + base32lower(raw)
            const b32 = try zat.multibase.encode(alloc, .base32lower, c.raw);
            defer alloc.free(b32);
            try writer.writeAll("{\"$link\":\"b");
            try writer.writeAll(b32);
            try writer.writeAll("\"}");
        },
        .bytes => |b| {
            const enc = std.base64.standard.Encoder;
            const out = try alloc.alloc(u8, enc.calcSize(b.len));
            defer alloc.free(out);
            _ = enc.encode(out, b);
            try writer.writeAll("{\"$bytes\":\"");
            try writer.writeAll(out);
            try writer.writeAll("\"}");
        },
    }
}

fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            0...0x07, 0x0b, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

test "serialize nested map with cid and string escaping" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    const entries = [_]cbor.Value.MapEntry{
        .{ .key = "title", .value = .{ .text = "hi \"there\"\n" } },
        .{ .key = "n", .value = .{ .unsigned = 42 } },
        .{ .key = "ok", .value = .{ .boolean = true } },
    };
    try writeValue(&out.writer, alloc, .{ .map = &entries });
    try std.testing.expectEqualStrings(
        "{\"title\":\"hi \\\"there\\\"\\n\",\"n\":42,\"ok\":true}",
        out.written(),
    );
}
