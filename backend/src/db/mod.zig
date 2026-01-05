const std = @import("std");
const Allocator = std.mem.Allocator;

const Client = @import("Client.zig");
const schema = @import("schema.zig");
const result = @import("result.zig");

// submodules
pub const activity = @import("activity.zig");
const search_ = @import("search.zig");
const stats_ = @import("stats.zig");
const write_ = @import("write.zig");

// re-exports
pub const Row = result.Row;
pub const BatchResult = result.BatchResult;
pub const Statement = Client.Statement;
pub const Stats = stats_.Stats;

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

// activity (direct re-export)
pub const initActivity = activity.init;
pub const getActivityCounts = activity.getCounts;

// search
pub fn search(alloc: Allocator, query: []const u8, tag_filter: ?[]const u8) ![]const u8 {
    const c = &(client orelse return error.NotInitialized);
    return search_.search(c, alloc, query, tag_filter);
}

pub fn findSimilar(alloc: Allocator, uri: []const u8, limit: usize) ![]const u8 {
    const c = &(client orelse return error.NotInitialized);
    return search_.findSimilar(c, alloc, uri, limit);
}

// stats
pub fn getTags(alloc: Allocator) ![]const u8 {
    const c = &(client orelse return error.NotInitialized);
    return stats_.getTags(c, alloc);
}

pub fn getStats() Stats {
    const c = &(client orelse return .{ .documents = 0, .publications = 0, .searches = 0, .errors = 0, .started_at = 0 });
    return stats_.getStats(c);
}

pub fn recordSearch(query: []const u8) void {
    const c = &(client orelse return);
    stats_.recordSearch(c, query);
}

pub fn recordError() void {
    const c = &(client orelse return);
    stats_.recordError(c);
}

pub fn getPopular(alloc: Allocator, limit: usize) ![]const u8 {
    const c = &(client orelse return error.NotInitialized);
    return stats_.getPopular(c, alloc, limit);
}

// write
pub fn insertDocument(
    uri: []const u8,
    did: []const u8,
    rkey: []const u8,
    title: []const u8,
    content: []const u8,
    created_at: ?[]const u8,
    publication_uri: ?[]const u8,
    tags: []const []const u8,
) !void {
    const c = &(client orelse return error.NotInitialized);
    return write_.insertDocument(c, uri, did, rkey, title, content, created_at, publication_uri, tags);
}

pub fn insertPublication(
    uri: []const u8,
    did: []const u8,
    rkey: []const u8,
    name: []const u8,
    description: ?[]const u8,
    base_path: ?[]const u8,
) !void {
    const c = &(client orelse return error.NotInitialized);
    return write_.insertPublication(c, uri, did, rkey, name, description, base_path);
}

pub fn deleteDocument(uri: []const u8) void {
    const c = &(client orelse return);
    write_.deleteDocument(c, uri);
}

pub fn deletePublication(uri: []const u8) void {
    const c = &(client orelse return);
    write_.deletePublication(c, uri);
}
