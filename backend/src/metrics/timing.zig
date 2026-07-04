const std = @import("std");
const Io = std.Io;
const db = @import("../db.zig");
const logfire = @import("logfire");

/// endpoints we track latency for
pub const Endpoint = enum {
    search_keyword,
    search_semantic,
    search_hybrid,
    similar,
    tags,
    popular,
    recommended,
    recommended_top_authors,
    curators,
    subscribed,
    dashboard,
    timeline,
    activity,

    pub fn name(self: Endpoint) []const u8 {
        return @tagName(self);
    }

    /// Whether this endpoint counts toward the aggregate traffic chart. The
    /// dashboard's live indicator polls `/activity` once a second per open
    /// tab, so a single stats page left open dwarfs real request volume —
    /// that's an implementation detail of the UI, not traffic to the product.
    pub fn countsAsTraffic(self: Endpoint) bool {
        return self != .activity;
    }
};

const SAMPLE_COUNT = 1000;
const ENDPOINT_COUNT = @typeInfo(Endpoint).@"enum".fields.len;
const PERSIST_PATH = "/data/timing.bin";
const PERSIST_PATH_HOURLY = "/data/timing_hourly.bin";
const HOURS_TO_KEEP = 720; // 30 days
const LATENCY_HISTORY_HOURS = 24; // default window embedded in /api/dashboard

/// Selectable window for the latency-history charts. The hourly buckets are
/// kept for `HOURS_TO_KEEP` (30 days), so any of these resolve against the
/// same in-memory ring buffer — the API just slices what the caller asks for.
pub const LatencyRange = enum {
    h24,
    d7,
    d30,

    pub fn fromString(s: []const u8) LatencyRange {
        if (std.mem.eql(u8, s, "24h")) return .h24;
        if (std.mem.eql(u8, s, "7d")) return .d7;
        if (std.mem.eql(u8, s, "30d")) return .d30;
        return .h24;
    }

    pub fn hours(self: LatencyRange) usize {
        return switch (self) {
            .h24 => 24,
            .d7 => 24 * 7,
            .d30 => HOURS_TO_KEEP, // 720
        };
    }
};

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

/// hourly bucket for time series
const HourlyBucket = struct {
    hour: i64 = 0, // unix timestamp of hour start
    count: u32 = 0,
    sum_us: u64 = 0,
    max_us: u32 = 0,

    fn record(self: *HourlyBucket, hour: i64, latency_us: u32) void {
        if (self.hour != hour) {
            // new hour, reset
            self.hour = hour;
            self.count = 0;
            self.sum_us = 0;
            self.max_us = 0;
        }
        self.count += 1;
        self.sum_us += latency_us;
        if (latency_us > self.max_us) self.max_us = latency_us;
    }
};

/// time series data point for API response
pub const TimeSeriesPoint = struct {
    hour: i64,
    count: u32,
    avg_ms: f64,
    max_ms: f64,
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
var hourly: [ENDPOINT_COUNT][HOURS_TO_KEEP]HourlyBucket = [_][HOURS_TO_KEEP]HourlyBucket{[_]HourlyBucket{.{}} ** HOURS_TO_KEEP} ** ENDPOINT_COUNT;
var mutex: Io.Mutex = Io.Mutex.init;
var global_io: ?Io = null;
var initialized: bool = false;

pub fn setIo(io: Io) void {
    global_io = io;
    // background persist: timing files flush every 30s, NOT per request.
    // persisting inside record() put two fly-volume file writes under a
    // global mutex on EVERY request — a volume latency spike serialized the
    // entire process (all endpoints stalling together, 2026-06-10). Worst
    // case now: 30s of latency samples lost on a crash.
    const t = std.Thread.spawn(.{}, persistLoop, .{}) catch return;
    t.detach();
}

fn persistLoop() void {
    const io = getIo();
    while (true) {
        io.sleep(Io.Duration.fromSeconds(30), .awake) catch {};
        {
            mutex.lockUncancelable(io);
            defer mutex.unlock(io);
            if (!initialized) continue;
            persistLocked();
            persistHourlyLocked();
        }
        // durable mirror to turso, OUTSIDE the mutex (network I/O must never be
        // held under the per-request lock — 2026-06-10 lesson). Self-no-ops if
        // turso/initialization isn't ready.
        flushToTurso();
    }
}

fn endpointFromName(name: []const u8) ?Endpoint {
    inline for (@typeInfo(Endpoint).@"enum".fields) |f| {
        if (std.mem.eql(u8, name, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

/// Upsert the current + previous hour's per-endpoint buckets to turso. Cheap
/// (≤ 2×ENDPOINT_COUNT rows) and off the request path. The previous hour is
/// included so an hour's final values land after the boundary rolls.
pub fn flushToTurso() void {
    const io = getIo();
    const c = db.getClient() orelse return;

    const Pending = struct { hour: i64, ep: usize, b: HourlyBucket };
    var pending: [2 * ENDPOINT_COUNT]Pending = undefined;
    var n: usize = 0;
    {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (!initialized) return;
        const cur = getCurrentHour();
        for ([_]i64{ cur, cur - 3600 }) |hr| {
            const idx = getHourIndex(hr);
            for (0..ENDPOINT_COUNT) |ep| {
                const b = hourly[ep][idx];
                if (b.hour == hr and b.count > 0) {
                    pending[n] = .{ .hour = hr, .ep = ep, .b = b };
                    n += 1;
                }
            }
        }
    }
    // network outside the lock
    for (pending[0..n]) |p| {
        const ep_name = @tagName(@as(Endpoint, @enumFromInt(p.ep)));
        var buf: [384]u8 = undefined;
        const sql = std.fmt.bufPrint(
            &buf,
            "INSERT INTO traffic_hourly (hour, endpoint, count, sum_us, max_us) VALUES ({d}, '{s}', {d}, {d}, {d}) ON CONFLICT(hour, endpoint) DO UPDATE SET count=excluded.count, sum_us=excluded.sum_us, max_us=excluded.max_us",
            .{ p.hour, ep_name, p.b.count, p.b.sum_us, p.b.max_us },
        ) catch continue;
        c.execRuntime(sql, &.{}) catch {};
    }
}

/// Load the last HOURS_TO_KEEP hours of per-endpoint buckets from turso into the
/// ring buffer. Call once at startup (after migrations). Authoritative over the
/// binary cache, so it survives both restarts and endpoint-enum resets.
pub fn loadFromTurso() void {
    const io = getIo();
    const c = db.getClient() orelse return;

    const cutoff = getCurrentHour() - @as(i64, HOURS_TO_KEEP) * 3600;
    var sql_buf: [128]u8 = undefined;
    const sql = std.fmt.bufPrint(&sql_buf, "SELECT hour, endpoint, count, sum_us, max_us FROM traffic_hourly WHERE hour >= {d}", .{cutoff}) catch return;
    var res = c.queryRuntime(sql, &.{}) catch |err| {
        logfire.warn("timing: loadFromTurso failed: {s}", .{@errorName(err)});
        return;
    };
    defer res.deinit();

    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    ensureInitialized();
    var loaded: usize = 0;
    for (res.rows) |row| {
        const hour = row.int(0);
        const ep = endpointFromName(row.text(1)) orelse continue;
        const idx = getHourIndex(hour);
        hourly[@intFromEnum(ep)][idx] = .{
            .hour = hour,
            .count = @intCast(@max(0, row.int(2))),
            .sum_us = @intCast(@max(0, row.int(3))),
            .max_us = @intCast(@max(0, row.int(4))),
        };
        loaded += 1;
    }
    logfire.info("timing: loaded {d} hourly buckets from turso", .{loaded});
}

fn getIo() Io {
    return global_io.?;
}

fn getCurrentHour() i64 {
    const now_s = @divFloor(timestamp(), 3600) * 3600;
    return now_s;
}

fn timestamp() i64 {
    return @intCast(@divFloor(Io.Timestamp.now(getIo(), .real).nanoseconds, std.time.ns_per_s));
}

fn microTimestamp() i64 {
    return Io.Timestamp.now(getIo(), .real).toMicroseconds();
}

fn getHourIndex(hour: i64) usize {
    // use hour as index into ring buffer
    return @intCast(@mod(@divFloor(hour, 3600), HOURS_TO_KEEP));
}

/// record a request latency (call after request completes)
pub fn record(endpoint: Endpoint, start_time: i64) void {
    const io = getIo();
    const now = microTimestamp();
    const elapsed_us: u32 = @intCast(@max(0, now - start_time));
    const current_hour = getCurrentHour();
    const hour_idx = getHourIndex(current_hour);

    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    ensureInitialized();

    const ep_idx = @intFromEnum(endpoint);
    buffers[ep_idx].record(elapsed_us);
    hourly[ep_idx][hour_idx].record(current_hour, elapsed_us);
    // memory-only: persistence happens on the background loop (see setIo).
    // NEVER do file/network I/O here — every handler runs through this
    // mutex on every request.
}

fn loadLocked() void {
    const fd = openForRead(PERSIST_PATH) orelse return;
    defer _ = std.c.close(fd);

    // read entire file at once (small file, ~16KB per endpoint)
    var file_buf: [ENDPOINT_COUNT * (@sizeOf([SAMPLE_COUNT]u32) + @sizeOf(usize) * 2 + @sizeOf(u64))]u8 = undefined;
    const bytes_read = readAll(fd, &file_buf) orelse return;
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
    const fd = openForWrite(PERSIST_PATH) orelse return;
    defer _ = std.c.close(fd);

    // write all buffers
    for (buffers) |buf| {
        writeAll(fd, std.mem.asBytes(&buf.samples));
        writeAll(fd, std.mem.asBytes(&buf.count));
        writeAll(fd, std.mem.asBytes(&buf.head));
        writeAll(fd, std.mem.asBytes(&buf.total_count));
    }
}

fn loadHourlyLocked() void {
    const fd = openForRead(PERSIST_PATH_HOURLY) orelse return;
    defer _ = std.c.close(fd);

    const bucket_size = @sizeOf(HourlyBucket);
    const total_size = ENDPOINT_COUNT * HOURS_TO_KEEP * bucket_size;
    var file_buf: [total_size]u8 = undefined;
    const bytes_read = readAll(fd, &file_buf) orelse return;
    if (bytes_read != total_size) return;

    var offset: usize = 0;
    for (&hourly) |*ep_buckets| {
        for (ep_buckets) |*bucket| {
            bucket.* = std.mem.bytesToValue(HourlyBucket, file_buf[offset..][0..bucket_size]);
            offset += bucket_size;
        }
    }
}

fn persistHourlyLocked() void {
    const fd = openForWrite(PERSIST_PATH_HOURLY) orelse return;
    defer _ = std.c.close(fd);

    for (hourly) |ep_buckets| {
        for (ep_buckets) |bucket| {
            writeAll(fd, std.mem.asBytes(&bucket));
        }
    }
}

// C file helpers (std.fs removed in 0.16)
fn openForRead(path: [*:0]const u8) ?std.c.fd_t {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    return if (fd < 0) null else fd;
}

fn openForWrite(path: [*:0]const u8) ?std.c.fd_t {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    return if (fd < 0) null else fd;
}

fn readAll(fd: std.c.fd_t, buf: []u8) ?usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.c.read(fd, buf[total..].ptr, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return total;
}

fn writeAll(fd: std.c.fd_t, data: []const u8) void {
    var total: usize = 0;
    while (total < data.len) {
        const n = std.c.write(fd, data[total..].ptr, data.len - total);
        if (n <= 0) return;
        total += @intCast(n);
    }
}

fn ensureInitialized() void {
    if (!initialized) {
        initialized = true;
        loadLocked();
        loadHourlyLocked();
    }
}

/// get stats for a specific endpoint
pub fn getStats(endpoint: Endpoint) EndpointStats {
    const io = getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    ensureInitialized();

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

/// get time series for an endpoint (last 24 hours, for latency charts)
pub fn getTimeSeries(endpoint: Endpoint) [LATENCY_HISTORY_HOURS]TimeSeriesPoint {
    const io = getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    ensureInitialized();
    var result: [LATENCY_HISTORY_HOURS]TimeSeriesPoint = undefined;
    fillTimeSeriesLocked(endpoint, LATENCY_HISTORY_HOURS, &result);
    return result;
}

/// get time series for all endpoints (24h)
pub fn getAllTimeSeries() [ENDPOINT_COUNT][LATENCY_HISTORY_HOURS]TimeSeriesPoint {
    var result: [ENDPOINT_COUNT][LATENCY_HISTORY_HOURS]TimeSeriesPoint = undefined;
    for (0..ENDPOINT_COUNT) |i| {
        result[i] = getTimeSeries(@enumFromInt(i));
    }
    return result;
}

/// Write up to `out.len` time-series points (one per hour, oldest first) for
/// `endpoint` into the caller-provided slice. `out.len` must be ≤ HOURS_TO_KEEP.
/// Used by the `/api/latency?range=...` endpoint to slice an arbitrary window
/// out of the existing 30-day ring buffer without a fixed-size return type.
pub fn writeTimeSeries(endpoint: Endpoint, out: []TimeSeriesPoint) void {
    const io = getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    ensureInitialized();
    fillTimeSeriesLocked(endpoint, out.len, out);
}

/// Internal: fill `out[0..count]` with hourly points for `endpoint`,
/// oldest-first. Caller must hold the mutex and ensureInitialized.
fn fillTimeSeriesLocked(endpoint: Endpoint, count: usize, out: []TimeSeriesPoint) void {
    std.debug.assert(out.len >= count);
    std.debug.assert(count <= HOURS_TO_KEEP);

    const current_hour = getCurrentHour();
    const ep_buckets = hourly[@intFromEnum(endpoint)];

    for (0..count) |i| {
        const hours_ago = count - 1 - i;
        const hour = current_hour - @as(i64, @intCast(hours_ago)) * 3600;
        const idx = getHourIndex(hour);
        const bucket = ep_buckets[idx];

        if (bucket.hour == hour and bucket.count > 0) {
            out[i] = .{
                .hour = hour,
                .count = bucket.count,
                .avg_ms = @as(f64, @floatFromInt(bucket.sum_us)) / @as(f64, @floatFromInt(bucket.count)) / 1000.0,
                .max_ms = @as(f64, @floatFromInt(bucket.max_us)) / 1000.0,
            };
        } else {
            out[i] = .{ .hour = hour, .count = 0, .avg_ms = 0, .max_ms = 0 };
        }
    }
}

/// traffic data point (aggregate across all endpoints)
pub const TrafficPoint = struct {
    hour: i64,
    count: u32,
};

/// get aggregate traffic series (all endpoints summed, last 720 hours)
pub fn getTrafficSeries() [HOURS_TO_KEEP]TrafficPoint {
    const io = getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    ensureInitialized();

    const current_hour = getCurrentHour();
    var result: [HOURS_TO_KEEP]TrafficPoint = undefined;

    for (0..HOURS_TO_KEEP) |i| {
        const hours_ago = HOURS_TO_KEEP - 1 - i;
        const hour = current_hour - @as(i64, @intCast(hours_ago)) * 3600;
        const idx = getHourIndex(hour);

        var total: u32 = 0;
        for (0..ENDPOINT_COUNT) |ep| {
            if (!@as(Endpoint, @enumFromInt(ep)).countsAsTraffic()) continue;
            const bucket = hourly[ep][idx];
            if (bucket.hour == hour) {
                total += bucket.count;
            }
        }
        result[i] = .{ .hour = hour, .count = total };
    }
    return result;
}

test "activity poll is excluded from traffic aggregate" {
    // /activity is a per-tab liveness poll (1/s); it must not inflate the
    // aggregate traffic chart. Every other endpoint counts as real traffic.
    try std.testing.expect(!Endpoint.activity.countsAsTraffic());
    inline for (@typeInfo(Endpoint).@"enum".fields) |f| {
        const ep = @field(Endpoint, f.name);
        if (ep != .activity) try std.testing.expect(ep.countsAsTraffic());
    }
}
