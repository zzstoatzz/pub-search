const std = @import("std");
const net = std.net;
const http = std.http;
const mem = std.mem;
const db = @import("db.zig");

pub fn handleConnection(conn: net.Server.Connection) void {
    defer conn.stream.close();

    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;

    var reader = conn.stream.reader(&read_buffer);
    var writer = conn.stream.writer(&write_buffer);

    var server = http.Server.init(reader.interface(), &writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| {
            if (err != error.HttpConnectionClosing and err != error.EndOfStream) {
                std.debug.print("http receive error: {}\n", .{err});
            }
            return;
        };
        handleRequest(&server, &request) catch |err| {
            std.debug.print("request error: {}\n", .{err});
            return;
        };
        if (!request.head.keep_alive) return;
    }
}

fn handleRequest(server: *http.Server, request: *http.Server.Request) !void {
    _ = server;
    const target = request.head.target;

    // cors preflight
    if (request.head.method == .OPTIONS) {
        try sendCorsHeaders(request, "");
        return;
    }

    if (mem.startsWith(u8, target, "/search")) {
        try handleSearch(request, target);
    } else if (mem.eql(u8, target, "/stats")) {
        try handleStats(request);
    } else if (mem.eql(u8, target, "/health")) {
        try sendJson(request, "{\"status\":\"ok\"}");
    } else {
        try sendNotFound(request);
    }
}

fn handleSearch(request: *http.Server.Request, target: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // parse query param: /search?q=something
    const query = blk: {
        if (mem.indexOf(u8, target, "?q=")) |idx| {
            const encoded = target[idx + 3 ..];
            // find end of query param (next & or end of string)
            const end = mem.indexOf(u8, encoded, "&") orelse encoded.len;
            const query_encoded = encoded[0..end];
            // decode percent-encoding
            const buf = try alloc.dupe(u8, query_encoded);
            break :blk std.Uri.percentDecodeInPlace(buf);
        }
        break :blk "";
    };

    if (query.len == 0) {
        try sendJson(request, "{\"error\":\"missing q parameter\"}");
        return;
    }

    // perform FTS search - arena handles cleanup
    const results = try db.searchDocuments(alloc, query);
    try sendJson(request, results);
}

fn handleStats(request: *http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const stats = db.getStats();

    var response: std.ArrayList(u8) = .{};
    defer response.deinit(alloc);

    try response.print(alloc, "{{\"documents\":{d},\"publications\":{d}}}", .{ stats.documents, stats.publications });

    try sendJson(request, response.items);
}

fn sendJson(request: *http.Server.Request, body: []const u8) !void {
    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = "*" },
            .{ .name = "access-control-allow-methods", .value = "GET, OPTIONS" },
            .{ .name = "access-control-allow-headers", .value = "content-type" },
        },
    });
}

fn sendCorsHeaders(request: *http.Server.Request, body: []const u8) !void {
    try request.respond(body, .{
        .status = .no_content,
        .extra_headers = &.{
            .{ .name = "access-control-allow-origin", .value = "*" },
            .{ .name = "access-control-allow-methods", .value = "GET, OPTIONS" },
            .{ .name = "access-control-allow-headers", .value = "content-type" },
        },
    });
}

fn sendNotFound(request: *http.Server.Request) !void {
    try request.respond("{\"error\":\"not found\"}", .{
        .status = .not_found,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
    });
}
