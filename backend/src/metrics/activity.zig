const std = @import("std");
const compat = @import("../compat.zig");

// ring buffer for real-time search activity
pub const SLOTS = 60;
const TICK_MS = 100;

var counts: [SLOTS]u16 = .{0} ** SLOTS;
var slot: usize = 0;
var mutex: compat.Mutex = .{};
var thread: ?std.Thread = null;

fn tickLoop() void {
    while (true) {
        compat.sleepMs(TICK_MS);
        mutex.lock();
        slot = (slot + 1) % SLOTS;
        counts[slot] = 0;
        mutex.unlock();
    }
}

pub fn init() void {
    thread = std.Thread.spawn(.{}, tickLoop, .{}) catch null;
}

pub fn getCounts() [SLOTS]u16 {
    mutex.lock();
    defer mutex.unlock();
    var result: [SLOTS]u16 = undefined;
    for (0..SLOTS) |i| {
        const idx = (slot + 1 + i) % SLOTS;
        result[i] = counts[idx];
    }
    return result;
}

pub fn record() void {
    mutex.lock();
    defer mutex.unlock();
    counts[slot] +|= 1;
}
