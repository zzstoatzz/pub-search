const std = @import("std");

/// endpoints we track latency for
pub const Endpoint = enum {
    search,
    similar,
    tags,
    popular,

    pub fn name(self: Endpoint) []const u8 {
        return @tagName(self);
    }
};

const SAMPLE_COUNT = 1000;
const ENDPOINT_COUNT = @typeInfo(Endpoint).@"enum".fields.len;

/// per-endpoint latency buffer
const LatencyBuffer = struct {
    samples: [SAMPLE_COUNT]u32 = .{0} ** SAMPLE_COUNT, // microseconds
    count: usize = 0,
    head: usize = 0,
    total_count: u64 = 0,

    fn record(self: *LatencyBuffer, latency_us: u32) void {
        self.samples[self.head] = latency_us;
        self.head = (self.head + 1) % SAMPLE_COUNT;
        if (self.count < SAMPLE_COUNT) self.count += 1;
        self.total_count += 1;
    }
};

/// computed stats for an endpoint
pub const EndpointStats = struct {
    count: u64 = 0,
    avg_ms: f64 = 0,
    p50_ms: f64 = 0,
    p95_ms: f64 = 0,
    p99_ms: f64 = 0,
    max_ms: f64 = 0,
};

var buffers: [ENDPOINT_COUNT]LatencyBuffer = [_]LatencyBuffer{.{}} ** ENDPOINT_COUNT;
var mutex: std.Thread.Mutex = .{};

/// record a request latency (call after request completes)
pub fn record(endpoint: Endpoint, start_time: i64) void {
    const now = std.time.microTimestamp();
    const elapsed_us: u32 = @intCast(@max(0, now - start_time));

    mutex.lock();
    defer mutex.unlock();
    buffers[@intFromEnum(endpoint)].record(elapsed_us);
}

/// get stats for a specific endpoint
pub fn getStats(endpoint: Endpoint) EndpointStats {
    mutex.lock();
    defer mutex.unlock();

    const buf = &buffers[@intFromEnum(endpoint)];
    if (buf.count == 0) return .{};

    // copy and sort for percentiles
    var sorted: [SAMPLE_COUNT]u32 = undefined;
    @memcpy(sorted[0..buf.count], buf.samples[0..buf.count]);
    std.mem.sort(u32, sorted[0..buf.count], {}, std.sort.asc(u32));

    var sum: u64 = 0;
    for (sorted[0..buf.count]) |v| sum += v;

    const count = buf.count;
    return .{
        .count = buf.total_count,
        .avg_ms = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(count)) / 1000.0,
        .p50_ms = @as(f64, @floatFromInt(sorted[count / 2])) / 1000.0,
        .p95_ms = @as(f64, @floatFromInt(sorted[(count * 95) / 100])) / 1000.0,
        .p99_ms = @as(f64, @floatFromInt(sorted[(count * 99) / 100])) / 1000.0,
        .max_ms = @as(f64, @floatFromInt(sorted[count - 1])) / 1000.0,
    };
}

/// get stats for all endpoints
pub fn getAllStats() [ENDPOINT_COUNT]EndpointStats {
    var result: [ENDPOINT_COUNT]EndpointStats = undefined;
    for (0..ENDPOINT_COUNT) |i| {
        result[i] = getStats(@enumFromInt(i));
    }
    return result;
}
