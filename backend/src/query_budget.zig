//! Process-local budget and bounded cache for paid Voyage query embeddings.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const DEFAULT_LIMIT: u32 = 2000;
pub const CACHE_CAPACITY: usize = 1024;
const DAY_SECONDS: i64 = 86400;

pub const Budget = struct {
    mutex: Io.Mutex = .init,
    limit: u32 = DEFAULT_LIMIT,
    day: i64 = -1,
    used: u32 = 0,
    vectors: std.StringHashMapUnmanaged([]f32) = .empty,
    order: std.ArrayList([]const u8) = .empty,
    next_evict: usize = 0,

    pub fn take(self: *Budget, io: Io, now_s: i64) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const day = @divFloor(now_s, DAY_SECONDS);
        if (day != self.day) {
            self.day = day;
            self.used = 0;
        }
        if (self.used >= self.limit) return false;
        self.used += 1;
        return true;
    }

    pub fn lookup(self: *Budget, io: Io, alloc: Allocator, query: []const u8) ?[]f32 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const vector = self.vectors.get(query) orelse return null;
        return alloc.dupe(f32, vector) catch null;
    }

    pub fn remember(self: *Budget, io: Io, query: []const u8, vector: []const f32) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.vectors.contains(query)) return;
        const alloc = std.heap.page_allocator;
        const key = alloc.dupe(u8, query) catch return;
        const copy = alloc.dupe(f32, vector) catch {
            alloc.free(key);
            return;
        };
        self.vectors.put(alloc, key, copy) catch {
            alloc.free(key);
            alloc.free(copy);
            return;
        };
        if (self.order.items.len < CACHE_CAPACITY) {
            self.order.append(alloc, key) catch {
                _ = self.vectors.remove(key);
                alloc.free(key);
                alloc.free(copy);
            };
        } else {
            const old = self.order.items[self.next_evict];
            if (self.vectors.fetchRemove(old)) |entry| alloc.free(entry.value);
            alloc.free(old);
            self.order.items[self.next_evict] = key;
            self.next_evict = (self.next_evict + 1) % CACHE_CAPACITY;
        }
    }

    pub fn deinit(self: *Budget, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const alloc = std.heap.page_allocator;
        for (self.order.items) |key| alloc.free(key);
        var it = self.vectors.valueIterator();
        while (it.next()) |value| alloc.free(value.*);
        self.vectors.deinit(alloc);
        self.order.deinit(alloc);
    }
};

pub fn normalize(alloc: Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    var out = try alloc.alloc(u8, trimmed.len);
    var len: usize = 0;
    var spaced = false;
    for (trimmed) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (!spaced) {
                out[len] = ' ';
                len += 1;
            }
            spaced = true;
        } else {
            out[len] = std.ascii.toLower(byte);
            len += 1;
            spaced = false;
        }
    }
    return alloc.realloc(out, len);
}

test "budget caps paid queries per UTC day while cached vectors remain available" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var budget: Budget = .{ .limit = 1 };
    defer budget.deinit(io);
    try std.testing.expect(budget.take(io, 1));
    budget.remember(io, "zig", &.{ 1, 2 });
    try std.testing.expect(!budget.take(io, 2));
    const hit = budget.lookup(io, std.testing.allocator, "zig").?;
    defer std.testing.allocator.free(hit);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2 }, hit);
    try std.testing.expect(budget.take(io, DAY_SECONDS));
}

test "query cache evicts its oldest entry" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var budget: Budget = .{};
    defer budget.deinit(io);
    budget.remember(io, "first", &.{1});
    var name: [32]u8 = undefined;
    for (0..CACHE_CAPACITY) |i| {
        const key = try std.fmt.bufPrint(&name, "q{d}", .{i});
        budget.remember(io, key, &.{@floatFromInt(i)});
    }
    try std.testing.expect(budget.lookup(io, std.testing.allocator, "first") == null);
    try std.testing.expectEqual(CACHE_CAPACITY, budget.vectors.count());
}

test "query normalization shares case and whitespace variants" {
    const value = try normalize(std.testing.allocator, "  Zig\t  SEARCH \n");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("zig search", value);
}
