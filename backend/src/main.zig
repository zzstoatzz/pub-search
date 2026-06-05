const std = @import("std");
const Io = std.Io;
const Thread = std.Thread;
const logfire = @import("logfire");
const db = @import("db.zig");
const tpuf = @import("tpuf.zig");
const metrics = @import("metrics.zig");
const server = @import("server.zig");
const ingest = @import("ingest.zig");

const SOCKET_TIMEOUT_SECS = 5;

// multi-threaded debug_io — required for safe std.debug.print from worker threads
var threaded_io: Io.Threaded = undefined;
pub const std_options_debug_threaded_io: ?*Io.Threaded = &threaded_io;

// route every `std.log.*` call through logfire's OTEL log pipeline so
// stdlib + dependency log output is queryable in logfire alongside spans.
// active once `logfire.configure(...)` runs (it calls std_log_bridge.init);
// before that the bridge falls back to std.log.defaultLog (stderr).
pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = logfire.logFn,
};

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    // init Io backend for networking
    threaded_io = Io.Threaded.init(allocator, .{});
    const io = threaded_io.io();

    // configure logfire (reads LOGFIRE_WRITE_TOKEN from env)
    _ = logfire.configure(.{
        .service_name = "leaflet-search",
        .service_version = "0.1.0",
        .environment = if (std.c.getenv("FLY_APP_NAME")) |p| std.mem.span(p) else "development",
    }) catch |err| {
        std.debug.print("logfire init failed: {}, continuing without observability\n", .{err});
    };

    // start http server FIRST so Fly proxy doesn't timeout
    const port: u16 = blk: {
        const port_str = if (std.c.getenv("PORT")) |p| std.mem.span(p) else "3000";
        break :blk std.fmt.parseInt(u16, port_str, 10) catch 3000;
    };

    const address = Io.net.Ip4Address.unspecified(port);
    var listener = (Io.net.IpAddress{ .ip4 = address }).listen(io, .{ .reuse_address = true }) catch |err| {
        logfire.err("failed to listen on port {d}: {}", .{ port, err });
        return err;
    };
    defer listener.deinit(io);

    const app_name = if (std.c.getenv("APP_NAME")) |p| std.mem.span(p) else "leaflet-search";
    logfire.info("{s} listening on port {d}", .{ app_name, port });

    // init turso client synchronously (fast, needed for search fallback)
    try db.initTurso(io);

    // metrics modules just need `io` stashed so per-request handlers can
    // record latency / activity safely. these MUST be initialized before
    // the listener accept loop starts, otherwise the first poll of /activity
    // or /stats hits `global_io.?` and SIGABRTs the process. the heavier
    // services that depend on the local replica stay in initServices.
    metrics.activity.init(io);
    metrics.timing.setIo(io);
    metrics.buffer.init(io);

    // read vector-store config (env-only, no I/O) before the accept loop.
    // isSemanticEnabled() gates semantic search on these keys; if init ran
    // later in the background initServices thread (behind slow schema
    // migrations + local-db sync), every deploy served "semantic search not
    // available" for the whole startup window. keepalive (network) stays async.
    tpuf.init(io);

    // init local db and other services in background (slow)
    const init_thread = try Thread.spawn(.{}, initServices, .{ allocator, io });
    init_thread.detach();

    // thread-per-connection (Thread.Pool removed in 0.16)
    while (true) {
        const stream = listener.accept(io) catch |err| {
            logfire.err("accept error: {}", .{err});
            continue;
        };

        setSocketTimeout(stream.socket.handle, SOCKET_TIMEOUT_SECS) catch |err| {
            logfire.warn("failed to set socket timeout: {}", .{err});
        };

        const accepted_at = Io.Timestamp.now(io, .real).toMicroseconds();
        const thread = Thread.spawn(.{}, server.handleConnection, .{ stream, io, accepted_at }) catch |err| {
            logfire.err("spawn error: {}", .{err});
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn initServices(allocator: std.mem.Allocator, io: Io) void {
    // run schema migrations first (idempotent, but may be slow if turso is laggy)
    db.initSchema();

    // init local db (slow - turso already initialized)
    db.initLocalDb(io);
    db.startSync(io);

    // metrics.activity / metrics.buffer / metrics.timing are now initialized
    // up in main() before the listener starts so request handlers can safely
    // call record() on them.

    // tpuf.init() ran synchronously in main() before the accept loop (it is
    // env-only and gates semantic search). keepalive does network I/O, so it
    // stays here in the background.
    tpuf.startKeepalive(allocator);

    // keep turso connection warm (avoids ~1s TLS handshake on first query after idle)
    db.startKeepalive();

    // seed + start the background refresh for /recommended and /curators
    // so leaderboard pages never block user requests on a remote Turso query.
    server.initRecommendedCache(io);
    server.initCuratorsCache(io);

    // prune search_events older than 90 days on each boot. Bounded
    // growth + natural privacy hygiene; the popular-searches window is
    // only 7 days so anything older has no read consumer.
    if (db.getClient()) |c| {
        c.exec("DELETE FROM search_events WHERE at < strftime('%s', 'now') - 90 * 86400", &.{}) catch {};
    }

    // start reconciler (verifies documents still exist at source PDS)
    ingest.reconciler.start(allocator, io);

    // start embedder (voyage-4-lite, 1024 dims, 1 worker)
    ingest.embedder.start(allocator, io);

    // start tap consumer
    ingest.tap.consumer(allocator, io);
}

fn setSocketTimeout(fd: std.posix.fd_t, secs: u32) !void {
    const timeout = std.mem.toBytes(std.posix.timeval{
        .sec = @intCast(secs),
        .usec = 0,
    });
    try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &timeout);
    try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, &timeout);
}

// Force the test runner to include `test "..."` blocks from non-root modules.
// Without this, only tests literally inside main.zig would run — referencing
// a module via `pub const X = @import("x.zig").X` does not pull in `x.zig`'s
// test blocks. Add new test-bearing files here as they appear.
test {
    _ = @import("db/Client.zig");
    _ = @import("db/zug_conn.zig");
    _ = @import("db/migrations.zig");
    _ = @import("ingest/extractor.zig");
    _ = @import("server/search.zig");
}
