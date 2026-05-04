//! Adapter that exposes a `*Client` as a zug-shaped SQLite connection.
//!
//! `zug.sqlite.run` expects:
//!   - `exec(sql: []const u8, args: anytype) !void`
//!   - `rows(sql: []const u8, args: anytype) !Rows`  // .next() -> ?Row, .deinit()
//!   - row.text(i) []const u8 / row.int(i) i64
//!
//! zug binds two arg types in practice:
//!   - `[]const u8` for ids, names, checksums, and class tags
//!   - `i64`        for the `dirty` flag column
//!
//! Anything else is a compile error so we catch surprises early. Adding a new
//! supported type is a one-line addition to `runtimeValueFrom`.
//!
//! This file does NOT import `zug`. It just duck-types into the trait zug
//! validates with `validateConn`. zug becomes a build dep in phase 3 when we
//! actually call `zug.sqlite.run(allocator, &conn, &migrations, .{})`.

const std = @import("std");
const Client = @import("Client.zig");

pub const MigrationConn = struct {
    client: *Client,

    pub fn init(client: *Client) MigrationConn {
        return .{ .client = client };
    }

    pub fn exec(self: *MigrationConn, sql: []const u8, args: anytype) !void {
        const fields = comptime tupleFields(@TypeOf(args));
        var buf: [fields.len]Client.RuntimeValue = undefined;
        argsToRuntimeValues(args, buf[0..]);
        return self.client.execRuntime(sql, buf[0..]);
    }

    pub fn rows(self: *MigrationConn, sql: []const u8, args: anytype) !Rows {
        const fields = comptime tupleFields(@TypeOf(args));
        var buf: [fields.len]Client.RuntimeValue = undefined;
        argsToRuntimeValues(args, buf[0..]);
        return .{ .result = try self.client.queryRuntime(sql, buf[0..]) };
    }

    /// Iterator wrapper over `Client.Result.rows` — returns each row as the
    /// existing `Client.Row`, which already provides `text(i)` / `int(i)`.
    pub const Rows = struct {
        result: Client.Result,
        index: usize = 0,

        pub fn next(self: *Rows) ?Client.Row {
            if (self.index >= self.result.rows.len) return null;
            defer self.index += 1;
            return self.result.rows[self.index];
        }

        pub fn deinit(self: *Rows) void {
            self.result.deinit();
        }
    };
};

/// Extract the field list of a tuple/struct, handling pointer-to-tuple too.
fn tupleFields(comptime ArgsType: type) []const std.builtin.Type.StructField {
    const info = @typeInfo(ArgsType);
    if (info == .pointer) {
        const child = @typeInfo(info.pointer.child);
        if (child == .@"struct") return child.@"struct".fields;
    }
    if (info == .@"struct") return info.@"struct".fields;
    @compileError("MigrationConn args must be a tuple or pointer to tuple, got " ++ @typeName(ArgsType));
}

fn argsToRuntimeValues(args: anytype, out: []Client.RuntimeValue) void {
    const fields = comptime tupleFields(@TypeOf(args));
    inline for (fields, 0..) |field, i| {
        out[i] = runtimeValueFrom(@field(args, field.name));
    }
}

fn runtimeValueFrom(v: anytype) Client.RuntimeValue {
    const T = @TypeOf(v);
    if (T == []const u8) return .{ .text = v };
    if (T == i64) return .{ .int = v };
    @compileError("MigrationConn args must be []const u8 or i64; got " ++ @typeName(T));
}

// --- tests ---

test "argsToRuntimeValues: empty tuple" {
    var buf: [0]Client.RuntimeValue = undefined;
    argsToRuntimeValues(.{}, buf[0..]);
    try std.testing.expectEqual(@as(usize, 0), buf.len);
}

test "argsToRuntimeValues: single string slice" {
    const id: []const u8 = "001_initial";
    var buf: [1]Client.RuntimeValue = undefined;
    argsToRuntimeValues(.{id}, buf[0..]);

    try std.testing.expect(buf[0] == .text);
    try std.testing.expectEqualStrings("001_initial", buf[0].text);
}

test "argsToRuntimeValues: single i64" {
    const dirty: i64 = 1;
    var buf: [1]Client.RuntimeValue = undefined;
    argsToRuntimeValues(.{dirty}, buf[0..]);

    try std.testing.expect(buf[0] == .int);
    try std.testing.expectEqual(@as(i64, 1), buf[0].int);
}

test "argsToRuntimeValues: zug INSERT-shaped tuple (4 strings + i64)" {
    // Mirrors what zug.sqlite's `insertMigration` passes for a startup migration.
    const id: []const u8 = "001_create_documents";
    const name: []const u8 = "create documents table";
    const checksum: []const u8 = "deadbeef00000000";
    const class_tag: []const u8 = "startup";
    const dirty: i64 = 1;

    var buf: [5]Client.RuntimeValue = undefined;
    argsToRuntimeValues(.{ id, name, checksum, class_tag, dirty }, buf[0..]);

    try std.testing.expectEqualStrings("001_create_documents", buf[0].text);
    try std.testing.expectEqualStrings("create documents table", buf[1].text);
    try std.testing.expectEqualStrings("deadbeef00000000", buf[2].text);
    try std.testing.expectEqualStrings("startup", buf[3].text);
    try std.testing.expectEqual(@as(i64, 1), buf[4].int);
}

test "argsToRuntimeValues: zug UPDATE-shaped tuple (i64 + string)" {
    // Mirrors what zug.sqlite's `markDirty` passes.
    const dirty: i64 = 0;
    const id: []const u8 = "001_create_documents";
    var buf: [2]Client.RuntimeValue = undefined;
    argsToRuntimeValues(.{ dirty, id }, buf[0..]);

    try std.testing.expectEqual(@as(i64, 0), buf[0].int);
    try std.testing.expectEqualStrings("001_create_documents", buf[1].text);
}

test "MigrationConn.Rows: iterates Hrana response shape" {
    // Hand-rolled response that mirrors what Turso returns for
    // `SELECT id, checksum, dirty FROM zug_migrations`.
    const fake_hrana_response =
        \\{"results":[{"response":{"result":{"rows":[
        \\  [
        \\    {"type":"text","value":"001_initial"},
        \\    {"type":"text","value":"deadbeef00000000"},
        \\    {"type":"integer","value":"0"}
        \\  ],
        \\  [
        \\    {"type":"text","value":"002_add_email"},
        \\    {"type":"text","value":"cafef00d00000000"},
        \\    {"type":"integer","value":"1"}
        \\  ]
        \\]}}}]}
    ;

    var result = try Client.Result.parse(std.testing.allocator, fake_hrana_response);
    defer result.deinit();

    var rows: MigrationConn.Rows = .{ .result = result };
    // Don't deinit `rows` separately — `result` already owns the data and
    // `rows.deinit` would double-free.

    const r1 = rows.next() orelse return error.MissingFirstRow;
    try std.testing.expectEqualStrings("001_initial", r1.text(0));
    try std.testing.expectEqualStrings("deadbeef00000000", r1.text(1));
    try std.testing.expectEqual(@as(i64, 0), r1.int(2));

    const r2 = rows.next() orelse return error.MissingSecondRow;
    try std.testing.expectEqualStrings("002_add_email", r2.text(0));
    try std.testing.expectEqualStrings("cafef00d00000000", r2.text(1));
    try std.testing.expectEqual(@as(i64, 1), r2.int(2));

    try std.testing.expect(rows.next() == null);
}

test "MigrationConn.Rows: empty result" {
    const fake_empty_response =
        \\{"results":[{"response":{"result":{"rows":[]}}}]}
    ;
    var result = try Client.Result.parse(std.testing.allocator, fake_empty_response);
    defer result.deinit();

    var rows: MigrationConn.Rows = .{ .result = result };
    try std.testing.expect(rows.next() == null);
}
