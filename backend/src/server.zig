const std = @import("std");
const net = std.net;
const http = std.http;
const mem = std.mem;
const activity = @import("activity.zig");
const search = @import("search.zig");
const stats = @import("stats.zig");
const dashboard = @import("dashboard.zig");

const HTTP_BUF_SIZE = 8192;
const QUERY_PARAM_BUF_SIZE = 64;

pub fn handleConnection(conn: net.Server.Connection) void {
    defer conn.stream.close();

    var read_buffer: [HTTP_BUF_SIZE]u8 = undefined;
    var write_buffer: [HTTP_BUF_SIZE]u8 = undefined;

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
    } else if (mem.eql(u8, target, "/tags")) {
        try handleTags(request);
    } else if (mem.eql(u8, target, "/stats")) {
        try handleStats(request);
    } else if (mem.eql(u8, target, "/health")) {
        try sendJson(request, "{\"status\":\"ok\"}");
    } else if (mem.eql(u8, target, "/popular")) {
        try handlePopular(request);
    } else if (mem.eql(u8, target, "/dashboard")) {
        try handleDashboard(request);
    } else if (mem.eql(u8, target, "/api/dashboard")) {
        try handleDashboardApi(request);
    } else if (mem.startsWith(u8, target, "/similar")) {
        try handleSimilar(request, target);
    } else if (mem.eql(u8, target, "/activity")) {
        try handleActivity(request);
    } else {
        try sendNotFound(request);
    }
}

fn handleSearch(request: *http.Server.Request, target: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // parse query params: /search?q=something&tag=foo&platform=leaflet
    const query = parseQueryParam(alloc, target, "q") catch "";
    const tag_filter = parseQueryParam(alloc, target, "tag") catch null;
    const platform_filter = parseQueryParam(alloc, target, "platform") catch null;

    if (query.len == 0 and tag_filter == null) {
        try sendJson(request, "{\"error\":\"enter a search term\"}");
        return;
    }

    // perform FTS search - arena handles cleanup
    const results = search.search(alloc, query, tag_filter, platform_filter) catch |err| {
        stats.recordError();
        return err;
    };
    stats.recordSearch(query);
    try sendJson(request, results);
}

fn handleTags(request: *http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tags = try stats.getTags(alloc);
    try sendJson(request, tags);
}

fn handlePopular(request: *http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const popular = try stats.getPopular(alloc, 5);
    try sendJson(request, popular);
}

fn parseQueryParam(alloc: std.mem.Allocator, target: []const u8, param: []const u8) ![]const u8 {
    // look for ?param= or &param=
    const patterns = [_][]const u8{ "?", "&" };
    for (patterns) |prefix| {
        var search_buf: [QUERY_PARAM_BUF_SIZE]u8 = undefined;
        const search_str = std.fmt.bufPrint(&search_buf, "{s}{s}=", .{ prefix, param }) catch continue;
        if (mem.indexOf(u8, target, search_str)) |idx| {
            const encoded = target[idx + search_str.len ..];
            const end = mem.indexOf(u8, encoded, "&") orelse encoded.len;
            const query_encoded = encoded[0..end];
            const buf = try alloc.dupe(u8, query_encoded);
            // decode + as space (form-urlencoded), then percent-decode
            for (buf) |*c| {
                if (c.* == '+') c.* = ' ';
            }
            return std.Uri.percentDecodeInPlace(buf);
        }
    }
    return error.NotFound;
}

fn handleStats(request: *http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const db_stats = stats.getStats();

    var response: std.ArrayList(u8) = .{};
    defer response.deinit(alloc);

    try response.print(alloc, "{{\"documents\":{d},\"publications\":{d},\"cache_hits\":{d},\"cache_misses\":{d}}}", .{ db_stats.documents, db_stats.publications, db_stats.cache_hits, db_stats.cache_misses });

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

fn handleDashboardApi(request: *http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const data = dashboard.fetch(alloc) catch {
        try sendJson(request, "{\"error\":\"failed to fetch dashboard data\"}");
        return;
    };

    const json_response = dashboard.toJson(alloc, data) catch {
        try sendJson(request, "{\"error\":\"failed to serialize dashboard data\"}");
        return;
    };

    try sendJson(request, json_response);
}

fn handleDashboard(request: *http.Server.Request) !void {
    try request.respond("", .{
        .status = .moved_permanently,
        .extra_headers = &.{
            .{ .name = "location", .value = "https://leaflet-search.pages.dev/dashboard.html" },
        },
    });
}

fn handleSimilar(request: *http.Server.Request, target: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const uri = parseQueryParam(alloc, target, "uri") catch {
        try sendJson(request, "{\"error\":\"missing uri parameter\"}");
        return;
    };

    const results = search.findSimilar(alloc, uri, 5) catch {
        try sendJson(request, "[]");
        return;
    };

    try sendJson(request, results);
}

fn handleActivity(request: *http.Server.Request) !void {
    const counts = activity.getCounts();

    // format as JSON array
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    writer.writeByte('[') catch return;
    for (counts, 0..) |c, i| {
        if (i > 0) writer.writeByte(',') catch return;
        writer.print("{d}", .{c}) catch return;
    }
    writer.writeByte(']') catch return;

    try sendJson(request, stream.getWritten());
}
