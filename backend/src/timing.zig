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
const PERSIST_PATH = "/data/timing.bin";
const PERSIST_INTERVAL = 100; // save every N records

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
var records_since_persist: u32 = 0;
var initialized: bool = false;

/// record a request latency (call after request completes)
pub fn record(endpoint: Endpoint, start_time: i64) void {
    const now = std.time.microTimestamp();
    const elapsed_us: u32 = @intCast(@max(0, now - start_time));

    mutex.lock();
    defer mutex.unlock();

    if (!initialized) {
        initialized = true;
        loadLocked();
    }

    buffers[@intFromEnum(endpoint)].record(elapsed_us);

    // persist periodically
    records_since_persist += 1;
    if (records_since_persist >= PERSIST_INTERVAL) {
        records_since_persist = 0;
        persistLocked();
    }
}

fn loadLocked() void {
    const file = std.fs.openFileAbsolute(PERSIST_PATH, .{}) catch return;
    defer file.close();

    // read entire file at once (small file, ~16KB per endpoint)
    var file_buf: [ENDPOINT_COUNT * (@sizeOf([SAMPLE_COUNT]u32) + @sizeOf(usize) * 2 + @sizeOf(u64))]u8 = undefined;
    const bytes_read = file.readAll(&file_buf) catch return;
    if (bytes_read != file_buf.len) return; // incomplete file

    var offset: usize = 0;
    for (&buffers) |*buf| {
        const samples_size = @sizeOf([SAMPLE_COUNT]u32);
        buf.samples = std.mem.bytesToValue([SAMPLE_COUNT]u32, file_buf[offset..][0..samples_size]);
        offset += samples_size;

        buf.count = std.mem.readInt(usize, file_buf[offset..][0..@sizeOf(usize)], .little);
        offset += @sizeOf(usize);

        buf.head = std.mem.readInt(usize, file_buf[offset..][0..@sizeOf(usize)], .little);
        offset += @sizeOf(usize);

        buf.total_count = std.mem.readInt(u64, file_buf[offset..][0..@sizeOf(u64)], .little);
        offset += @sizeOf(u64);
    }
}

fn persistLocked() void {
    const file = std.fs.createFileAbsolute(PERSIST_PATH, .{}) catch return;
    defer file.close();

    // write all buffers
    for (buffers) |buf| {
        file.writeAll(std.mem.asBytes(&buf.samples)) catch return;
        file.writeAll(std.mem.asBytes(&buf.count)) catch return;
        file.writeAll(std.mem.asBytes(&buf.head)) catch return;
        file.writeAll(std.mem.asBytes(&buf.total_count)) catch return;
    }
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
