const std = @import("std");
const Io = std.Io;

// ring buffer for real-time search activity
pub const SLOTS = 60;
const TICK_MS = 100;

var counts: [SLOTS]u16 = .{0} ** SLOTS;
var slot: usize = 0;
var mutex: Io.Mutex = Io.Mutex.init;
var global_io: ?Io = null;

fn tickLoop() void {
    const io = global_io.?;
    while (true) {
        io.sleep(Io.Duration.fromMilliseconds(TICK_MS), .awake) catch {};
        mutex.lockUncancelable(io);
        slot = (slot + 1) % SLOTS;
        counts[slot] = 0;
        mutex.unlock(io);
    }
}

pub fn init(io: Io) void {
    global_io = io;
    const thread = std.Thread.spawn(.{}, tickLoop, .{}) catch return;
    thread.detach();
}

pub fn getCounts() [SLOTS]u16 {
    const io = global_io.?;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    var result: [SLOTS]u16 = undefined;
    for (0..SLOTS) |i| {
        const idx = (slot + 1 + i) % SLOTS;
        result[i] = counts[idx];
    }
    return result;
}

pub fn record() void {
    const io = global_io.?;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    counts[slot] +|= 1;
}
