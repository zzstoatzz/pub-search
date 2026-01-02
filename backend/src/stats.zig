const std = @import("std");
const Atomic = std.atomic.Value;

/// Service stats - in-memory counters, Turso-backed totals
pub const Stats = struct {
    started_at: i64,
    searches: Atomic(u64),
    errors: Atomic(u64),

    pub fn init() Stats {
        return .{
            .started_at = std.time.timestamp(),
            .searches = Atomic(u64).init(0),
            .errors = Atomic(u64).init(0),
        };
    }

    pub fn recordSearch(self: *Stats) void {
        _ = self.searches.fetchAdd(1, .monotonic);
    }

    pub fn recordError(self: *Stats) void {
        _ = self.errors.fetchAdd(1, .monotonic);
    }

    pub fn getUptime(self: *const Stats) i64 {
        return std.time.timestamp() - self.started_at;
    }

    pub fn getSearches(self: *const Stats) u64 {
        return self.searches.load(.monotonic);
    }

    pub fn getErrors(self: *const Stats) u64 {
        return self.errors.load(.monotonic);
    }
};

var global_stats: Stats = undefined;
var initialized: bool = false;

pub fn init() void {
    global_stats = Stats.init();
    initialized = true;
}

pub fn get() *Stats {
    if (!initialized) init();
    return &global_stats;
}
