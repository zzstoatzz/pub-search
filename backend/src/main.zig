const std = @import("std");
const net = std.net;
const posix = std.posix;
const Thread = std.Thread;
const logfire = @import("logfire");
const db = @import("db/mod.zig");
const tpuf = @import("tpuf.zig");
const metrics = @import("metrics/mod.zig");
const server = @import("server/mod.zig");
const ingest = @import("ingest/mod.zig");

const MAX_HTTP_WORKERS = 16;
const SOCKET_TIMEOUT_SECS = 5;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // configure logfire (reads LOGFIRE_WRITE_TOKEN from env)
    _ = logfire.configure(.{
        .service_name = "leaflet-search",
        .service_version = "0.1.0",
        .environment = posix.getenv("FLY_APP_NAME") orelse "development",
    }) catch |err| {
        std.debug.print("logfire init failed: {}, continuing without observability\n", .{err});
    };

    // start http server FIRST so Fly proxy doesn't timeout
    const port: u16 = blk: {
        const port_str = posix.getenv("PORT") orelse "3000";
        break :blk std.fmt.parseInt(u16, port_str, 10) catch 3000;
    };

    const address = try net.Address.parseIp("0.0.0.0", port);
    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();

    const app_name = posix.getenv("APP_NAME") orelse "leaflet-search";
    logfire.info("{s} listening on port {d} (max {d} workers)", .{ app_name, port, MAX_HTTP_WORKERS });

    // init turso client synchronously (fast, needed for search fallback)
    try db.initTurso();

    // init thread pool for http connections
    var pool: Thread.Pool = undefined;
    try pool.init(.{
        .allocator = allocator,
        .n_jobs = MAX_HTTP_WORKERS,
    });
    defer pool.deinit();

    // init local db and other services in background (slow)
    const init_thread = try Thread.spawn(.{}, initServices, .{allocator});
    init_thread.detach();

    while (true) {
        const conn = listener.accept() catch |err| {
            logfire.err("accept error: {}", .{err});
            continue;
        };

        setSocketTimeout(conn.stream.handle, SOCKET_TIMEOUT_SECS) catch |err| {
            logfire.warn("failed to set socket timeout: {}", .{err});
        };

        const accepted_at = std.time.microTimestamp();
        pool.spawn(server.handleConnection, .{ conn, accepted_at }) catch |err| {
            logfire.err("pool spawn error: {}", .{err});
            conn.stream.close();
        };
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

    // start reconciler (verifies documents still exist at source PDS)
    ingest.reconciler.start(allocator);

    // start embedder (voyage-4-lite, 1024 dims, 1 worker)
    ingest.embedder.start(allocator);

    // start tap consumer
    ingest.tap.consumer(allocator);
}

fn setSocketTimeout(fd: posix.fd_t, secs: u32) !void {
    const timeout = std.mem.toBytes(posix.timeval{
        .sec = @intCast(secs),
        .usec = 0,
    });
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout);
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout);
}
