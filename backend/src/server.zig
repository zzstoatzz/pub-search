const std = @import("std");
const net = std.net;
const http = std.http;
const mem = std.mem;
const json = std.json;
const logfire = @import("logfire");
const activity = @import("activity.zig");
const search = @import("search.zig");
const stats = @import("stats.zig");
const timing = @import("timing.zig");
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
                logfire.debug("http receive error: {}", .{err});
            }
            return;
        };
        handleRequest(&server, &request) catch |err| {
            logfire.err("request error: {}", .{err});
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
    } else if (mem.eql(u8, target, "/platforms")) {
        try handlePlatforms(request);
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
    const start_time = std.time.microTimestamp();
    defer timing.record(.search, start_time);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const query = parseQueryParam(alloc, target, "q") catch "";
    const tag_filter = parseQueryParam(alloc, target, "tag") catch null;
    const platform_filter = parseQueryParam(alloc, target, "platform") catch null;
    const since_filter = parseQueryParam(alloc, target, "since") catch null;

    // span attributes are now copied internally, safe to use arena strings
    const span = logfire.span("http.search", .{
        .query = query,
        .tag = tag_filter,
        .platform = platform_filter,
    });
    defer span.end();

    if (query.len == 0 and tag_filter == null) {
        try sendJson(request, "{\"error\":\"enter a search term\"}");
        return;
    }

    // perform FTS search - arena handles cleanup
    const results = search.search(alloc, query, tag_filter, platform_filter, since_filter) catch |err| {
        logfire.err("search failed: {}", .{err});
        stats.recordError();
        return err;
    };
    stats.recordSearch(query);
    logfire.counter("search.requests", 1);
    try sendJson(request, results);
}

fn handleTags(request: *http.Server.Request) !void {
    const start_time = std.time.microTimestamp();
    defer timing.record(.tags, start_time);

    const span = logfire.span("http.tags", .{});
    defer span.end();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tags = try stats.getTags(alloc);
    try sendJson(request, tags);
}

fn handlePopular(request: *http.Server.Request) !void {
    const start_time = std.time.microTimestamp();
    defer timing.record(.popular, start_time);

    const span = logfire.span("http.popular", .{});
    defer span.end();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const popular = try stats.getPopular(alloc, 5);
    try sendJson(request, popular);
}

fn handlePlatforms(request: *http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const data = try stats.getPlatformCounts(alloc);
    try sendJson(request, data);
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
    const all_timing = timing.getAllStats();

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginObject();

    // db stats
    try jw.objectField("documents");
    try jw.write(db_stats.documents);
    try jw.objectField("publications");
    try jw.write(db_stats.publications);
    try jw.objectField("embeddings");
    try jw.write(db_stats.embeddings);
    try jw.objectField("searches");
    try jw.write(db_stats.searches);
    try jw.objectField("errors");
    try jw.write(db_stats.errors);
    try jw.objectField("cache_hits");
    try jw.write(db_stats.cache_hits);
    try jw.objectField("cache_misses");
    try jw.write(db_stats.cache_misses);

    // timing stats per endpoint
    try jw.objectField("timing");
    try jw.beginObject();
    inline for (@typeInfo(timing.Endpoint).@"enum".fields, 0..) |field, i| {
        const t = all_timing[i];
        try jw.objectField(field.name);
        try jw.beginObject();
        try jw.objectField("count");
        try jw.write(t.count);
        try jw.objectField("avg_ms");
        try jw.write(t.avg_ms);
        try jw.objectField("p50_ms");
        try jw.write(t.p50_ms);
        try jw.objectField("p95_ms");
        try jw.write(t.p95_ms);
        try jw.objectField("p99_ms");
        try jw.write(t.p99_ms);
        try jw.objectField("max_ms");
        try jw.write(t.max_ms);
        try jw.endObject();
    }
    try jw.endObject();

    try jw.endObject();

    try sendJson(request, try output.toOwnedSlice());
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

fn getDashboardUrl() []const u8 {
    return std.posix.getenv("DASHBOARD_URL") orelse "https://leaflet-search.pages.dev/dashboard.html";
}

fn handleDashboard(request: *http.Server.Request) !void {
    const dashboard_url = getDashboardUrl();
    try request.respond("", .{
        .status = .moved_permanently,
        .extra_headers = &.{
            .{ .name = "location", .value = dashboard_url },
        },
    });
}

fn handleSimilar(request: *http.Server.Request, target: []const u8) !void {
    const start_time = std.time.microTimestamp();
    defer timing.record(.similar, start_time);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const uri = parseQueryParam(alloc, target, "uri") catch {
        try sendJson(request, "{\"error\":\"missing uri parameter\"}");
        return;
    };

    // span attributes are copied internally, safe to use arena strings
    const span = logfire.span("http.similar", .{ .uri = uri });
    defer span.end();

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
