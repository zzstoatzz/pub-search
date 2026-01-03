const std = @import("std");
const net = std.net;
const posix = std.posix;
const Thread = std.Thread;
const db = @import("db/mod.zig");
const server = @import("server.zig");
const tap = @import("tap.zig");

const MAX_HTTP_WORKERS = 16;
const SOCKET_TIMEOUT_SECS = 30;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // init turso
    try db.init();

    // start activity tracker
    db.initActivity();

    // start tap consumer in background
    const tap_thread = try Thread.spawn(.{}, tap.consumer, .{allocator});
    defer tap_thread.join();

    // init thread pool for http connections
    var pool: Thread.Pool = undefined;
    try pool.init(.{
        .allocator = allocator,
        .n_jobs = MAX_HTTP_WORKERS,
    });
    defer pool.deinit();

    // start http server
    const port: u16 = blk: {
        const port_str = posix.getenv("PORT") orelse "3000";
        break :blk std.fmt.parseInt(u16, port_str, 10) catch 3000;
    };

    const address = try net.Address.parseIp("0.0.0.0", port);
    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();

    std.debug.print("leaflet-search listening on http://0.0.0.0:{d} (max {} workers)\n", .{ port, MAX_HTTP_WORKERS });

    while (true) {
        const conn = listener.accept() catch |err| {
            std.debug.print("accept error: {}\n", .{err});
            continue;
        };

        setSocketTimeout(conn.stream.handle, SOCKET_TIMEOUT_SECS) catch |err| {
            std.debug.print("failed to set socket timeout: {}\n", .{err});
        };

        pool.spawn(server.handleConnection, .{conn}) catch |err| {
            std.debug.print("pool spawn error: {}\n", .{err});
            conn.stream.close();
        };
    }
}

fn setSocketTimeout(fd: posix.fd_t, secs: u32) !void {
    const timeout = std.mem.toBytes(posix.timeval{
        .sec = @intCast(secs),
        .usec = 0,
    });
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout);
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout);
}
