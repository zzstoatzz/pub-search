const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

/// A single row from a query result
pub const Row = struct {
    columns: []const json.Value,

    pub fn text(self: Row, index: usize) []const u8 {
        if (index >= self.columns.len) return "";
        return extractText(self.columns[index]);
    }

    pub fn int(self: Row, index: usize) i64 {
        if (index >= self.columns.len) return 0;
        return extractInt(self.columns[index]);
    }
};

/// Parsed query result with rows
pub const Result = struct {
    allocator: Allocator,
    parsed: ?json.Parsed(json.Value),
    rows: []const Row,

    pub fn parse(allocator: Allocator, response: []const u8) !Result {
        const parsed = json.parseFromSlice(json.Value, allocator, response, .{}) catch {
            return .{ .allocator = allocator, .parsed = null, .rows = &.{} };
        };

        const json_rows = getRowsFromParsed(parsed.value) orelse {
            return .{ .allocator = allocator, .parsed = parsed, .rows = &.{} };
        };

        var rows: std.ArrayList(Row) = .{};
        errdefer rows.deinit(allocator);

        for (json_rows.items) |item| {
            if (item == .array) {
                try rows.append(allocator, .{ .columns = item.array.items });
            }
        }

        return .{
            .allocator = allocator,
            .parsed = parsed,
            .rows = try rows.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.rows);
        if (self.parsed) |*p| p.deinit();
    }

    pub fn count(self: Result) usize {
        return self.rows.len;
    }

    pub fn isEmpty(self: Result) bool {
        return self.rows.len == 0;
    }

    /// Get the first row, or null if empty
    pub fn first(self: Result) ?Row {
        if (self.rows.len == 0) return null;
        return self.rows[0];
    }
};

/// Navigate Turso's nested response format to get rows
fn getRowsFromParsed(value: json.Value) ?json.Array {
    const results = value.object.get("results") orelse return null;
    if (results != .array or results.array.items.len == 0) return null;

    const first = results.array.items[0];
    if (first != .object) return null;

    const resp = first.object.get("response") orelse return null;
    if (resp != .object) return null;

    const res = resp.object.get("result") orelse return null;
    if (res != .object) return null;

    const rows = res.object.get("rows") orelse return null;
    if (rows != .array) return null;

    return rows.array;
}

/// Extract text from a Turso value (handles both raw and typed formats)
pub fn extractText(val: json.Value) []const u8 {
    return switch (val) {
        .string => |s| s,
        .object => |obj| {
            const v = obj.get("value") orelse return "";
            return if (v == .string) v.string else "";
        },
        else => "",
    };
}

/// Extract integer from a Turso value (handles both raw and typed formats)
pub fn extractInt(val: json.Value) i64 {
    return switch (val) {
        .integer => |i| i,
        .object => |obj| {
            const v = obj.get("value") orelse return 0;
            return switch (v) {
                .integer => |i| i,
                .string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
                else => 0,
            };
        },
        else => 0,
    };
}
