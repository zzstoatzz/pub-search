const std = @import("std");
const Io = std.Io;
const Thread = std.Thread;
const logfire = @import("logfire");
const db = @import("db.zig");
const tpuf = @import("tpuf.zig");
const metrics = @import("metrics.zig");
const server = @import("server.zig");
const ingest = @import("ingest.zig");
const compat = @import("compat.zig");

const SOCKET_TIMEOUT_SECS = 5;

// multi-threaded debug_io — required for safe std.debug.print from worker threads
var threaded_io: Io.Threaded = undefined;
pub const std_options_debug_threaded_io: ?*Io.Threaded = &threaded_io;

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    // init Io backend for networking
    threaded_io = Io.Threaded.init(allocator, .{});
    const io = threaded_io.io();
    compat.initIo(io);

    // configure logfire (reads LOGFIRE_WRITE_TOKEN from env)
    _ = logfire.configure(.{
        .service_name = "leaflet-search",
        .service_version = "0.1.0",
        .environment = compat.getenv("FLY_APP_NAME") orelse "development",
    }) catch |err| {
        std.debug.print("logfire init failed: {}, continuing without observability\n", .{err});
    };

    // start http server FIRST so Fly proxy doesn't timeout
    const port: u16 = blk: {
        const port_str = compat.getenv("PORT") orelse "3000";
        break :blk std.fmt.parseInt(u16, port_str, 10) catch 3000;
    };

    const address = Io.net.Ip4Address.unspecified(port);
    var listener = (Io.net.IpAddress{ .ip4 = address }).listen(io, .{ .reuse_address = true }) catch |err| {
        logfire.err("failed to listen on port {d}: {}", .{ port, err });
        return err;
    };
    defer listener.deinit(io);

    const app_name = compat.getenv("APP_NAME") orelse "leaflet-search";
    logfire.info("{s} listening on port {d}", .{ app_name, port });

    // init turso client synchronously (fast, needed for search fallback)
    try db.initTurso(io);

    // init local db and other services in background (slow)
    const init_thread = try Thread.spawn(.{}, initServices, .{allocator});
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

        const accepted_at = compat.microTimestamp();
        const thread = Thread.spawn(.{}, server.handleConnection, .{ stream, io, accepted_at }) catch |err| {
            logfire.err("spawn error: {}", .{err});
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn initServices(allocator: std.mem.Allocator) void {
    // run schema migrations first (idempotent, but may be slow if turso is laggy)
    db.initSchema();

    // init local db (slow - turso already initialized)
    db.initLocalDb();
    db.startSync();

    // start activity tracker
    metrics.activity.init();

    // start stats buffer (background sync to Turso)
    metrics.buffer.init();

    // init vector store (reads TURBOPUFFER_API_KEY from env)
    tpuf.init();
    tpuf.startKeepalive(allocator);

    // keep turso connection warm (avoids ~1s TLS handshake on first query after idle)
    db.startKeepalive();

    // start reconciler (verifies documents still exist at source PDS)
    ingest.reconciler.start(allocator);

    // start embedder (voyage-4-lite, 1024 dims, 1 worker)
    ingest.embedder.start(allocator);

    // start tap consumer
    ingest.tap.consumer(allocator);
}

fn setSocketTimeout(fd: std.posix.fd_t, secs: u32) !void {
    const timeout = std.mem.toBytes(std.posix.timeval{
        .sec = @intCast(secs),
        .usec = 0,
    });
    try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &timeout);
    try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, &timeout);
}
