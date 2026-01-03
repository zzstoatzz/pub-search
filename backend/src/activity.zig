const std = @import("std");

/// Ring buffer - 60 slots at 100ms each = 6 second window
const SLOTS = 60;
const TICK_MS = 100;

var counts: [SLOTS]u16 = .{0} ** SLOTS;
var current_slot: usize = 0;
var mutex: std.Thread.Mutex = .{};
var tick_thread: ?std.Thread = null;

/// Start the background tick thread
pub fn init() void {
    tick_thread = std.Thread.spawn(.{}, tickLoop, .{}) catch null;
}

/// Record a search event
pub fn record() void {
    mutex.lock();
    defer mutex.unlock();
    counts[current_slot] +|= 1;
}

/// Get activity counts (oldest to newest)
pub fn getCounts() [SLOTS]u16 {
    mutex.lock();
    defer mutex.unlock();

    var result: [SLOTS]u16 = undefined;
    for (0..SLOTS) |i| {
        const idx = (current_slot + 1 + i) % SLOTS;
        result[i] = counts[idx];
    }
    return result;
}

/// Background thread - advances slot every 100ms
fn tickLoop() void {
    while (true) {
        std.Thread.sleep(TICK_MS * std.time.ns_per_ms);
        mutex.lock();
        current_slot = (current_slot + 1) % SLOTS;
        counts[current_slot] = 0;
        mutex.unlock();
    }
}
