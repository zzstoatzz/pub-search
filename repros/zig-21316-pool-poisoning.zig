// MRE: zig 0.16 std.http.Client pools a connection whose send failed.
//
// upstream: https://github.com/ziglang/zig/issues/21316 (open since 0.13;
// same root cause diagnosed there via EndOfStream — this is the RST/
// WriteFailed presentation, still unfixed on master as of 2026-07-07).
// this wedged prod 2026-07-06: turso killed idle keep-alive conns and every
// query failed with WriteFailed for 15min until restart. mitigation lives in
// backend/src/db/Client.zig (fetchEvictRetry) with a regression test.
// run: zig run repros/zig-21316-pool-poisoning.zig
//
// server answers one keep-alive request per connection, then closes with
// SO_LINGER=0 (RST) — an upstream killing an idle keep-alive connection.
// fetch #2 fails (expected: the pooled conn is dead), but the pool
// re-releases it as reusable (Request.deinit: reader.state == .ready →
// closing = false), so fetch #3 fails too and no new dial ever happens.
// a fresh client proves the server is still fine.

const std = @import("std");
const Io = std.Io;

const PORT: u16 = 39124;
var threaded_io: Io.Threaded = undefined;
var accepts = std.atomic.Value(u32).init(0);

fn serverThread(io: Io) void {
    var addr = Io.net.IpAddress.parseIp4("127.0.0.1", PORT) catch unreachable;
    var server = addr.listen(io, .{}) catch unreachable;
    while (true) {
        const stream = server.accept(io) catch return;
        _ = accepts.fetchAdd(1, .monotonic);
        var buf: [4096]u8 = undefined;
        _ = std.c.recv(stream.socket.handle, &buf, buf.len, 0);
        const resp = "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n";
        _ = std.c.send(stream.socket.handle, resp, resp.len, 0);
        const linger = std.c.linger{ .onoff = 1, .linger = 0 };
        _ = std.c.setsockopt(stream.socket.handle, std.c.SOL.SOCKET, std.c.SO.LINGER, &linger, @sizeOf(std.c.linger));
        stream.close(io);
    }
}

fn doFetch(client: *std.http.Client, url: []const u8, label: []const u8) void {
    const res = client.fetch(.{ .location = .{ .url = url }, .method = .GET });
    if (res) |r|
        std.debug.print("{s}: ok {d} (accepts: {d})\n", .{ label, @intFromEnum(r.status), accepts.load(.monotonic) })
    else |err|
        std.debug.print("{s}: ERROR {s} (accepts: {d})\n", .{ label, @errorName(err), accepts.load(.monotonic) });
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    threaded_io = Io.Threaded.init(allocator, .{});
    const io = threaded_io.io();

    _ = try std.Thread.spawn(.{}, serverThread, .{io});
    try io.sleep(.fromMilliseconds(100), .awake);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{PORT});

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    doFetch(&client, url, "fetch #1");
    try io.sleep(.fromMilliseconds(100), .awake); // let the server close the pooled conn
    doFetch(&client, url, "fetch #2"); // fails: pooled conn is dead (fine so far)
    doFetch(&client, url, "fetch #3"); // BUG: dead conn was re-pooled; no new dial

    var fresh: std.http.Client = .{ .allocator = allocator, .io = io };
    doFetch(&fresh, url, "fresh client"); // control: server is fine
}
