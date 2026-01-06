const std = @import("std");

const schema = @import("schema.zig");
const result = @import("result.zig");

// re-exports
pub const Client = @import("Client.zig");
pub const Row = result.Row;
pub const Result = result.Result;
pub const BatchResult = result.BatchResult;

// global state
var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var client: ?Client = null;

pub fn init() !void {
    client = try Client.init(gpa.allocator());
    try schema.init(&client.?);
}

pub fn getClient() ?*Client {
    if (client) |*c| return c;
    return null;
}
