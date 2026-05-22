const std = @import("std");
const Io = std.Io;
const http = std.http;
const mem = std.mem;
const json = std.json;
const Allocator = mem.Allocator;
const logfire = @import("logfire");
const zql = @import("zql");
const zat = @import("zat");
const db = @import("db.zig");
const metrics = @import("metrics.zig");
const search = @import("server/search.zig");
const dashboard = @import("server/dashboard.zig");

const HTTP_BUF_SIZE = 65536;
const QUERY_PARAM_BUF_SIZE = 64;

fn microTimestamp(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toMicroseconds();
}

pub fn handleConnection(stream: Io.net.Stream, io: Io, accepted_at: i64) void {
    defer stream.close(io);

    const queue_us = microTimestamp(io) - accepted_at;
    if (queue_us > 100_000) { // > 100ms
        logfire.warn("http.queue slow: {d}ms", .{@divTrunc(queue_us, 1000)});
    }

    var read_buffer: [HTTP_BUF_SIZE]u8 = undefined;
    var write_buffer: [HTTP_BUF_SIZE]u8 = undefined;

    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);

    var server = http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        const recv_start = microTimestamp(io);
        var request = server.receiveHead() catch |err| {
            if (err != error.HttpConnectionClosing and err != error.EndOfStream) {
                logfire.debug("http receive error: {}", .{err});
            }
            return;
        };
        const recv_us = microTimestamp(io) - recv_start;
        const target = request.head.target;

        const req_span = logfire.span("http.request", .{
            .target = target,
            .queue_ms = @divTrunc(queue_us, 1000),
            .receive_ms = @divTrunc(recv_us, 1000),
        });

        handleRequest(&server, &request, io) catch |err| {
            logfire.err("request error: {}", .{err});
            req_span.end();
            return;
        };
        req_span.end();

        if (!request.head.keep_alive) return;
    }
}

fn handleRequest(server: *http.Server, request: *http.Server.Request, io: Io) !void {
    _ = server;
    const target = request.head.target;

    // cors preflight
    if (request.head.method == .OPTIONS) {
        try sendCorsHeaders(request, "");
        return;
    }

    // extract path (before query string) for routing
    const path = if (mem.indexOf(u8, target, "?")) |qi| target[0..qi] else target;

    if (mem.startsWith(u8, path, "/search")) {
        try handleSearch(request, target, io);
    } else if (mem.eql(u8, path, "/tags")) {
        try handleTags(request, target, io);
    } else if (mem.eql(u8, path, "/stats")) {
        try handleStats(request);
    } else if (mem.eql(u8, path, "/health")) {
        try sendJson(request, "{\"status\":\"ok\"}");
    } else if (mem.eql(u8, path, "/popular")) {
        try handlePopular(request, target, io);
    } else if (mem.eql(u8, path, "/dashboard")) {
        try handleDashboard(request);
    } else if (mem.eql(u8, path, "/api/dashboard")) {
        try handleDashboardApi(request);
    } else if (mem.eql(u8, path, "/api/timeline")) {
        try handleTimelineApi(request, target);
    } else if (mem.eql(u8, path, "/api/latency")) {
        try handleLatencyApi(request, target);
    } else if (mem.eql(u8, path, "/recommended")) {
        try handleRecommended(request, target, io);
    } else if (mem.startsWith(u8, path, "/similar")) {
        try handleSimilar(request, target, io);
    } else if (mem.eql(u8, path, "/activity")) {
        try handleActivity(request);
    } else {
        try sendNotFound(request);
    }
}


fn handleSearch(request: *http.Server.Request, target: []const u8, io: Io) !void {
    const start_time = microTimestamp(io);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const query = parseQueryParam(alloc, target, "q") catch "";
    const tag_filter = parseQueryParam(alloc, target, "tag") catch null;
    const platform_filter = parseQueryParam(alloc, target, "platform") catch null;
    const since_filter = parseQueryParam(alloc, target, "since") catch null;
    const author_param = parseQueryParam(alloc, target, "author") catch null;
    const mode_str = parseQueryParam(alloc, target, "mode") catch null;
    const mode = search.SearchMode.fromString(mode_str);
    const format = parseQueryParam(alloc, target, "format") catch "v1";
    const limit_str = parseQueryParam(alloc, target, "limit") catch null;
    const offset_str = parseQueryParam(alloc, target, "offset") catch null;
    const limit = if (limit_str) |s| std.fmt.parseInt(usize, s, 10) catch 20 else 20;
    const offset = if (offset_str) |s| std.fmt.parseInt(usize, s, 10) catch 0 else 0;

    // resolve author param: if it's a handle (not a DID), resolve via AT Protocol
    const author_filter: ?[]const u8 = if (author_param) |ap| blk: {
        if (mem.startsWith(u8, ap, "did:")) break :blk ap;
        break :blk resolveHandle(alloc, ap, io) catch null;
    } else null;

    // record per-mode latency
    const timing_endpoint: metrics.timing.Endpoint = switch (mode) {
        .keyword => .search_keyword,
        .semantic => .search_semantic,
        .hybrid => .search_hybrid,
    };
    defer metrics.timing.record(timing_endpoint, start_time);

    // span attributes are now copied internally, safe to use arena strings
    const span = logfire.span("http.search", .{
        .query = query,
        .tag = tag_filter,
        .platform = platform_filter,
        .author = author_filter,
        .mode = @tagName(mode),
    });
    defer span.end();

    if (query.len == 0 and tag_filter == null and author_filter == null) {
        try sendJson(request, "{\"error\":\"enter a search term\"}");
        return;
    }

    // perform search - arena handles cleanup
    const results = search.search(alloc, query, tag_filter, platform_filter, since_filter, author_filter, mode) catch |err| {
        logfire.err("search failed: {}", .{err});
        metrics.stats.recordError();
        return err;
    };
    metrics.stats.recordSearch(query);
    logfire.counter("search.requests", 1);

    if (mem.eql(u8, format, "v2")) {
        const wrapped = try wrapResponse(alloc, results, query, @tagName(mode), limit, offset);
        try sendJson(request, wrapped);
    } else {
        // v1: apply pagination by slicing the JSON array
        if (offset > 0 or limit < 40) {
            const paginated = try paginateJsonArray(alloc, results, limit, offset);
            try sendJson(request, paginated);
        } else {
            try sendJson(request, results);
        }
    }
}

fn handleTags(request: *http.Server.Request, target: []const u8, io: Io) !void {
    const start_time = microTimestamp(io);
    defer metrics.timing.record(.tags, start_time);

    const span = logfire.span("http.tags", .{});
    defer span.end();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const format = parseQueryParam(alloc, target, "format") catch "v1";
    const tags = try getTags(alloc);

    if (mem.eql(u8, format, "v2")) {
        const wrapped = try wrapResponse(alloc, tags, "", "tags", 100, 0);
        try sendJson(request, wrapped);
    } else {
        try sendJson(request, tags);
    }
}

fn handlePopular(request: *http.Server.Request, target: []const u8, io: Io) !void {
    const start_time = microTimestamp(io);
    defer metrics.timing.record(.popular, start_time);

    const span = logfire.span("http.popular", .{});
    defer span.end();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const format = parseQueryParam(alloc, target, "format") catch "v1";
    const popular = try getPopular(alloc, 5);

    if (mem.eql(u8, format, "v2")) {
        const wrapped = try wrapResponse(alloc, popular, "", "popular", 100, 0);
        try sendJson(request, wrapped);
    } else {
        try sendJson(request, popular);
    }
}

// --- tags/popular query logic ---

const TagJson = struct { tag: []const u8, count: i64 };
const PopularJson = struct { query: []const u8, count: i64 };

const TagsQuery = zql.Query(dashboard.TAGS_SQL);

fn getTags(alloc: Allocator) ![]const u8 {
    // try local SQLite first (faster)
    if (db.getLocalDb()) |local| {
        if (getTagsLocal(alloc, local)) |result| {
            return result;
        } else |_| {}
    }

    // fall back to Turso
    const c = db.getClient() orelse return error.NotInitialized;

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var res = c.query(TagsQuery.positional, &.{}) catch {
        try output.writer.writeAll("{\"error\":\"failed to fetch tags\"}");
        return try output.toOwnedSlice();
    };
    defer res.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (res.rows) |row| try jw.write(TagJson{ .tag = row.text(0), .count = row.int(1) });
    try jw.endArray();
    return try output.toOwnedSlice();
}

fn getTagsLocal(alloc: Allocator, local: *db.LocalDb) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var rows = try local.query(dashboard.TAGS_SQL, .{});
    defer rows.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    while (rows.next()) |row| {
        try jw.write(TagJson{ .tag = row.text(0), .count = row.int(1) });
    }
    try jw.endArray();
    return try output.toOwnedSlice();
}

fn getPopular(alloc: Allocator, limit: usize) ![]const u8 {
    // try local SQLite first (faster)
    if (db.getLocalDb()) |local| {
        if (getPopularLocal(alloc, local, limit)) |result| {
            return result;
        } else |_| {}
    }

    // fall back to Turso
    const c = db.getClient() orelse return error.NotInitialized;

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var buf: [8]u8 = undefined;
    const limit_str = std.fmt.bufPrint(&buf, "{d}", .{limit}) catch "3";

    var res = c.query(
        "SELECT query, count FROM popular_searches ORDER BY count DESC LIMIT ?",
        &.{limit_str},
    ) catch {
        try output.writer.writeAll("[]");
        return try output.toOwnedSlice();
    };
    defer res.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (res.rows) |row| try jw.write(PopularJson{ .query = row.text(0), .count = row.int(1) });
    try jw.endArray();
    return try output.toOwnedSlice();
}

fn getPopularLocal(alloc: Allocator, local: *db.LocalDb, limit: usize) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    _ = limit; // zqlite doesn't support runtime LIMIT, use fixed 10
    var rows = try local.query(
        "SELECT query, count FROM popular_searches ORDER BY count DESC LIMIT 10",
        .{},
    );
    defer rows.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    while (rows.next()) |row| {
        try jw.write(PopularJson{ .query = row.text(0), .count = row.int(1) });
    }
    try jw.endArray();
    return try output.toOwnedSlice();
}

const RecommendedJson = struct {
    type: []const u8,
    uri: []const u8,
    did: []const u8,
    title: []const u8,
    createdAt: []const u8,
    rkey: []const u8,
    basePath: []const u8,
    platform: []const u8,
    path: []const u8,
    publicationName: []const u8,
    url: []const u8,
    recommendCount: i64,
};

// Recommends live only on Turso (not the local SQLite replica), so this
// handler queries Turso directly. Volume is small (~500 records at launch);
// page is not on a hot path. If usage grows, plumb recommends into LocalDb.
// We aggregate across two NSIDs (site.standard.graph.recommend +
// pub.leaflet.interactions.recommend), so the same person may show up
// twice for one document. COUNT(DISTINCT r.did) treats it as one vote
// — matches what Leaflet's own UI counts within its lexicon.

const RecommendWindow = enum {
    all,
    day,
    week,
    month,
    year,

    fn fromString(s: ?[]const u8) RecommendWindow {
        const str = s orelse return .all;
        if (mem.eql(u8, str, "day")) return .day;
        if (mem.eql(u8, str, "week")) return .week;
        if (mem.eql(u8, str, "month")) return .month;
        if (mem.eql(u8, str, "year")) return .year;
        return .all;
    }

    fn slug(self: RecommendWindow) []const u8 {
        return @tagName(self);
    }

    /// SQLite modifier for `DATE('now', '-N days')`. .all has no filter.
    fn dateModifier(self: RecommendWindow) ?[]const u8 {
        return switch (self) {
            .all => null,
            .day => "-1 days",
            .week => "-7 days",
            .month => "-30 days",
            .year => "-365 days",
        };
    }
};

/// Source-of-truth column for "when did this recommend happen":
///   created_at when set (the user's PDS record's createdAt)
///   indexed_at when not (reconciled records from constellation that
///                       didn't ship a createdAt — small minority).
const RECOMMEND_TIME_EXPR = "COALESCE(NULLIF(r.created_at, ''), r.indexed_at)";

// All-time variant (no WHERE filter).
const RECOMMENDED_SQL_ALL =
    \\SELECT d.uri, d.did, d.title, COALESCE(d.created_at, '') AS created_at,
    \\  d.rkey, COALESCE(d.base_path, '') AS base_path, d.platform,
    \\  COALESCE(d.path, '') AS path, d.has_publication,
    \\  COALESCE(p.name, '') AS publication_name,
    \\  COUNT(DISTINCT r.did) AS recommend_count
    \\FROM documents d
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\JOIN recommends r ON r.document_uri = d.uri
    \\GROUP BY d.uri
    \\ORDER BY recommend_count DESC, d.created_at DESC
    \\LIMIT 250
;

// Windowed variant — same shape, plus a DATE-comparison filter. `?` binds
// to the SQLite modifier string (e.g., "-7 days").
const RECOMMENDED_SQL_WINDOWED =
    \\SELECT d.uri, d.did, d.title, COALESCE(d.created_at, '') AS created_at,
    \\  d.rkey, COALESCE(d.base_path, '') AS base_path, d.platform,
    \\  COALESCE(d.path, '') AS path, d.has_publication,
    \\  COALESCE(p.name, '') AS publication_name,
    \\  COUNT(DISTINCT r.did) AS recommend_count
    \\FROM documents d
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\JOIN recommends r ON r.document_uri = d.uri
    \\WHERE DATE(COALESCE(NULLIF(r.created_at, ''), r.indexed_at)) >= DATE('now', ?)
    \\GROUP BY d.uri
    \\HAVING recommend_count > 0
    \\ORDER BY recommend_count DESC, d.created_at DESC
    \\LIMIT 250
;

// /recommended is served from an in-memory cache that a background thread
// refreshes every ~45s. The underlying query (Turso JOIN + GROUP BY across
// remote DB) takes 1–11s depending on Turso connection latency; the
// leaderboard moves slowly, so we never want a user request to block on it.
// One cache slot per supported time window so each `?since=` is fast.
const RecommendedCache = struct {
    mu: Io.Mutex = Io.Mutex.init,
    body: ?[]u8 = null, // page_allocator-owned
    fetched_at_ns: i128 = 0,
};
const WINDOW_COUNT = @typeInfo(RecommendWindow).@"enum".fields.len;
var recommended_caches: [WINDOW_COUNT]RecommendedCache = [_]RecommendedCache{.{}} ** WINDOW_COUNT;
var recommended_refresh_io: ?Io = null;
var recommended_refresh_thread: ?std.Thread = null;

const RECOMMENDED_REFRESH_INTERVAL_MS: u64 = 45_000;

/// Spawn a background thread that keeps the /recommended cache warm.
/// User requests then always read from memory — they never block on the
/// underlying Turso JOIN+GROUP BY (which can take 5–11s on cold connections).
///
/// Returns immediately. The first refresh happens on the background thread
/// without blocking the caller — initServices must not stall here, since
/// `tap.consumer` is invoked downstream and a stuck Turso call would leave
/// the firehose subscription unstarted.
pub fn initRecommendedCache(io: Io) void {
    recommended_refresh_io = io;
    recommended_refresh_thread = std.Thread.spawn(.{}, recommendedRefreshLoop, .{}) catch |err| {
        logfire.warn("recommended cache: refresh thread failed to start: {}", .{err});
        return;
    };
    if (recommended_refresh_thread) |t| t.detach();
    logfire.info("recommended cache: refresh loop running every {d}ms", .{RECOMMENDED_REFRESH_INTERVAL_MS});
}

fn recommendedRefreshLoop() void {
    const io = recommended_refresh_io orelse return;
    // first refresh immediately (no sleep), then on the configured cadence.
    refreshAllRecommendedCaches();
    while (true) {
        io.sleep(Io.Duration.fromMilliseconds(RECOMMENDED_REFRESH_INTERVAL_MS), .awake) catch {};
        refreshAllRecommendedCaches();
    }
}

fn refreshAllRecommendedCaches() void {
    inline for (@typeInfo(RecommendWindow).@"enum".fields) |f| {
        refreshRecommendedCache(@as(RecommendWindow, @enumFromInt(f.value)));
    }
}

fn refreshRecommendedCache(window: RecommendWindow) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const fresh = getRecommended(alloc, window) catch |err| {
        logfire.warn("recommended cache: refresh failed ({s}): {}", .{ window.slug(), err });
        return;
    };

    const stored = std.heap.page_allocator.dupe(u8, fresh) catch return;
    const io = recommended_refresh_io orelse {
        std.heap.page_allocator.free(stored);
        return;
    };
    const now_ns: i128 = Io.Timestamp.now(io, .real).nanoseconds;

    var cache = &recommended_caches[@intFromEnum(window)];
    cache.mu.lockUncancelable(io);
    defer cache.mu.unlock(io);
    if (cache.body) |old| std.heap.page_allocator.free(old);
    cache.body = stored;
    cache.fetched_at_ns = now_ns;
}

fn handleRecommended(request: *http.Server.Request, target: []const u8, io: Io) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const span = logfire.span("http.recommended", .{});
    defer span.end();

    const limit_str = parseQueryParam(alloc, target, "limit") catch null;
    const offset_str = parseQueryParam(alloc, target, "offset") catch null;
    const since_str = parseQueryParam(alloc, target, "since") catch null;
    const limit: usize = if (limit_str) |s| std.fmt.parseInt(usize, s, 10) catch 20 else 20;
    const offset: usize = if (offset_str) |s| std.fmt.parseInt(usize, s, 10) catch 0 else 0;
    const window = RecommendWindow.fromString(since_str);
    span.setAttribute("window", window.slug());

    // Grab a snapshot of the cached top-N JSON. Background loop refreshes
    // each window every 45s, so user requests never block on Turso.
    var snapshot: ?[]u8 = null;
    {
        var cache = &recommended_caches[@intFromEnum(window)];
        cache.mu.lockUncancelable(io);
        defer cache.mu.unlock(io);
        if (cache.body) |body| {
            snapshot = try alloc.dupe(u8, body);
            span.setAttribute("cache", "hit");
        }
    }

    if (snapshot == null) {
        // cold fallback (init hasn't seeded yet, or refresh failed every time
        // since boot). compute inline so the user still gets a response.
        span.setAttribute("cache", "cold");
        snapshot = try alloc.dupe(u8, try getRecommended(alloc, window));
    }

    const sliced = try sliceRecommendedJson(alloc, snapshot.?, limit, offset);
    try sendJson(request, sliced);
}

/// Parse the cached top-N JSON array and re-emit only [offset, offset+limit).
/// The cache layer keeps the slow Turso JOIN off the hot path; this slice is
/// pure in-process work (~ms for N=250).
fn sliceRecommendedJson(alloc: Allocator, body: []const u8, limit: usize, offset: usize) ![]const u8 {
    var parsed = json.parseFromSlice(json.Value, alloc, body, .{}) catch {
        // body was an error envelope, not an array — pass it through.
        return alloc.dupe(u8, body);
    };
    defer parsed.deinit();

    if (parsed.value != .array) return alloc.dupe(u8, body);
    const items = parsed.value.array.items;

    const start = @min(offset, items.len);
    const end = @min(start + limit, items.len);

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (items[start..end]) |item| try jw.write(item);
    try jw.endArray();
    return try output.toOwnedSlice();
}

fn getRecommended(alloc: Allocator, window: RecommendWindow) ![]const u8 {
    const c = db.getClient() orelse return error.NotInitialized;

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var res = blk: {
        if (window.dateModifier()) |mod| {
            break :blk c.query(RECOMMENDED_SQL_WINDOWED, &.{mod}) catch {
                try output.writer.writeAll("{\"error\":\"failed to fetch recommended\"}");
                return try output.toOwnedSlice();
            };
        } else {
            break :blk c.query(RECOMMENDED_SQL_ALL, &.{}) catch {
                try output.writer.writeAll("{\"error\":\"failed to fetch recommended\"}");
                return try output.toOwnedSlice();
            };
        }
    };
    defer res.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (res.rows) |row| {
        const did = row.text(1);
        const rkey = row.text(4);
        const base_path = row.text(5);
        const platform = row.text(6);
        const path = row.text(7);
        const has_publication = row.int(8) != 0;
        const doc_type: []const u8 = if (has_publication) "article" else "looseleaf";
        try jw.write(RecommendedJson{
            .type = doc_type,
            .uri = row.text(0),
            .did = did,
            .title = row.text(2),
            .createdAt = row.text(3),
            .rkey = rkey,
            .basePath = base_path,
            .platform = platform,
            .path = path,
            .publicationName = row.text(9),
            .url = search.buildDocUrl(alloc, doc_type, platform, base_path, path, rkey, did),
            .recommendCount = row.int(10),
        });
    }
    try jw.endArray();
    return try output.toOwnedSlice();
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

    const db_stats = metrics.stats.getStats();
    const all_timing = metrics.timing.getAllStats();

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
    try jw.objectField("started_at");
    try jw.write(db_stats.started_at);
    try jw.objectField("cache_hits");
    try jw.write(db_stats.cache_hits);
    try jw.objectField("cache_misses");
    try jw.write(db_stats.cache_misses);

    // timing stats per endpoint
    try jw.objectField("timing");
    try jw.beginObject();
    inline for (@typeInfo(metrics.timing.Endpoint).@"enum".fields, 0..) |field, i| {
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
    // public read-only API — wildcard origin, no credentials needed.
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

fn handleTimelineApi(request: *http.Server.Request, target: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const range_str = parseQueryParam(alloc, target, "range") catch "30d";
    const range = dashboard.TimelineRange.fromString(range_str);

    const json_response = dashboard.fetchTimeline(alloc, range) catch {
        try sendJson(request, "{\"error\":\"failed to fetch timeline\"}");
        return;
    };

    try sendJson(request, json_response);
}

fn handleLatencyApi(request: *http.Server.Request, target: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const range_str = parseQueryParam(alloc, target, "range") catch "24h";
    const range = metrics.timing.LatencyRange.fromString(range_str);

    const json_response = dashboard.fetchLatency(alloc, range) catch {
        try sendJson(request, "{\"error\":\"failed to fetch latency\"}");
        return;
    };

    try sendJson(request, json_response);
}

fn getDashboardUrl() []const u8 {
    return if (std.c.getenv("DASHBOARD_URL")) |p| std.mem.span(p) else "https://pub-search.waow.tech/dashboard.html";
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

fn handleSimilar(request: *http.Server.Request, target: []const u8, io: Io) !void {
    const start_time = microTimestamp(io);
    defer metrics.timing.record(.similar, start_time);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const uri = parseQueryParam(alloc, target, "uri") catch {
        try sendJson(request, "{\"error\":\"missing uri parameter\"}");
        return;
    };

    const format = parseQueryParam(alloc, target, "format") catch "v1";

    // span attributes are copied internally, safe to use arena strings
    const span = logfire.span("http.similar", .{ .uri = uri });
    defer span.end();

    const results = search.findSimilar(alloc, uri, 5) catch {
        if (mem.eql(u8, format, "v2")) {
            try sendJson(request, "{\"results\":[],\"total\":0,\"hasMore\":false}");
        } else {
            try sendJson(request, "[]");
        }
        return;
    };

    if (mem.eql(u8, format, "v2")) {
        const wrapped = try wrapResponse(alloc, results, "", "similar", 20, 0);
        try sendJson(request, wrapped);
    } else {
        try sendJson(request, results);
    }
}

/// Wrap a JSON array response in v2 envelope: {"results": [...], "total": N, "hasMore": bool}
fn wrapResponse(alloc: Allocator, array_json: []const u8, query: []const u8, mode: []const u8, limit: usize, offset: usize) ![]const u8 {
    // parse the array to count items and apply pagination
    const parsed = json.parseFromSlice(json.Value, alloc, array_json, .{}) catch {
        return array_json; // fallback to raw if parse fails
    };
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .array => |arr| arr.items,
        else => return array_json,
    };

    const total = items.len;
    const start = @min(offset, total);
    const end = @min(start + limit, total);
    const has_more = end < total;

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginObject();

    try jw.objectField("results");
    try jw.beginArray();
    for (items[start..end]) |item| {
        try jw.write(item);
    }
    try jw.endArray();

    try jw.objectField("total");
    try jw.write(total);

    try jw.objectField("hasMore");
    try jw.write(has_more);

    if (query.len > 0) {
        try jw.objectField("query");
        try jw.write(query);
    }

    if (mode.len > 0) {
        try jw.objectField("mode");
        try jw.write(mode);
    }

    try jw.endObject();
    return try output.toOwnedSlice();
}

/// Apply pagination to a JSON array (for v1 format with limit/offset)
fn paginateJsonArray(alloc: Allocator, array_json: []const u8, limit: usize, offset: usize) ![]const u8 {
    const parsed = json.parseFromSlice(json.Value, alloc, array_json, .{}) catch {
        return array_json;
    };
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .array => |arr| arr.items,
        else => return array_json,
    };

    const total = items.len;
    const start = @min(offset, total);
    const end = @min(start + limit, total);

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (items[start..end]) |item| {
        try jw.write(item);
    }
    try jw.endArray();
    return try output.toOwnedSlice();
}

/// Resolve an AT Protocol handle to a DID via zat's HandleResolver.
/// Tries HTTP .well-known first, falls back to DNS-over-HTTPS.
fn resolveHandle(alloc: std.mem.Allocator, handle: []const u8, io: Io) ![]const u8 {
    const parsed = zat.Handle.parse(handle) orelse {
        logfire.warn("resolveHandle: invalid handle: {s}", .{handle});
        return error.InvalidHandle;
    };

    var resolver = zat.HandleResolver.init(io, alloc);
    defer resolver.deinit();

    return resolver.resolve(parsed) catch |err| {
        logfire.warn("resolveHandle: failed for {s}: {}", .{ handle, err });
        return error.ResolveFailed;
    };
}

fn handleActivity(request: *http.Server.Request) !void {
    const counts = metrics.activity.getCounts();

    // format as JSON array manually into buffer
    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    buf[pos] = '[';
    pos += 1;
    for (counts, 0..) |c, i| {
        if (i > 0) {
            buf[pos] = ',';
            pos += 1;
        }
        const written = std.fmt.bufPrint(buf[pos..], "{d}", .{c}) catch return;
        pos += written.len;
    }
    buf[pos] = ']';
    pos += 1;

    try sendJson(request, buf[0..pos]);
}
