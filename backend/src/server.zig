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
const ingest = @import("ingest.zig");
const metrics = @import("metrics.zig");
const search = @import("server/search.zig");
const dashboard = @import("server/dashboard.zig");
const recommended = @import("server/recommended.zig");
const curators = @import("server/curators.zig");

pub const initRecommendedCache = recommended.init;
pub const initCuratorsCache = curators.init;

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
    } else if (mem.eql(u8, path, "/recommended-by-top-authors")) {
        try handleRecommendedByTopAuthors(request, target);
    } else if (mem.eql(u8, path, "/curators")) {
        try handleCurators(request, target);
    } else if (mem.startsWith(u8, path, "/similar")) {
        try handleSimilar(request, target, io);
    } else if (mem.eql(u8, path, "/activity")) {
        try handleActivity(request);
    } else if (mem.eql(u8, path, "/admin/backfill")) {
        try handleBackfill(request, target, io);
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

// Tag row matches both the Turso and local-SQLite query shape (SELECT tag, count …).
// Using a named struct + zql.Query.fromRow means adding/removing a column
// becomes a compile error rather than a runtime miscount.
const TagsQuery = zql.Query(dashboard.TAGS_SQL);
const TagsRow = struct { tag: []const u8, count: i64 };

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
    for (res.rows) |row| {
        const r = TagsQuery.fromRow(TagsRow, row);
        try jw.write(TagJson{ .tag = r.tag, .count = r.count });
    }
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
        const r = TagsQuery.fromRow(TagsRow, row);
        try jw.write(TagJson{ .tag = r.tag, .count = r.count });
    }
    try jw.endArray();
    return try output.toOwnedSlice();
}

// Window for the popular-searches aggregation. 7 days strikes a balance:
// long enough for low-traffic queries to show up, short enough that test/
// seed traffic from weeks ago doesn't dominate. Seeded historical events
// fully age out 14 days after migration (see migration 013 for the seed
// strategy).
const POPULAR_WINDOW_SECS: i64 = 7 * 24 * 60 * 60;

// Aggregate distinct events in the window. Fast: idx_search_events_at
// makes the date filter range-scan, and the post-filter set is small
// (at the current ~50 searches/day rate, 7d ≈ 350 events to group).
const PopularQuery = zql.Query(
    \\SELECT query, COUNT(*) AS n
    \\FROM search_events
    \\WHERE at >= strftime('%s', 'now') - ?
    \\GROUP BY query
    \\ORDER BY n DESC, query
    \\LIMIT ?
);
const PopularRow = struct { query: []const u8, n: i64 };

fn getPopular(alloc: Allocator, limit: usize) ![]const u8 {
    const c = db.getClient() orelse return error.NotInitialized;

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var lim_buf: [8]u8 = undefined;
    const limit_str = std.fmt.bufPrint(&lim_buf, "{d}", .{limit}) catch "5";
    var win_buf: [16]u8 = undefined;
    const window_str = std.fmt.bufPrint(&win_buf, "{d}", .{POPULAR_WINDOW_SECS}) catch "604800";

    var res = c.query(PopularQuery.positional, &.{ window_str, limit_str }) catch {
        try output.writer.writeAll("[]");
        return try output.toOwnedSlice();
    };
    defer res.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (res.rows) |row| {
        const r = PopularQuery.fromRow(PopularRow, row);
        try jw.write(PopularJson{ .query = r.query, .count = r.n });
    }
    try jw.endArray();
    return try output.toOwnedSlice();
}

/// Thin wrapper around `server/recommended.zig`. Parses query params,
/// pulls a cache snapshot (or live-queries for author-filtered views,
/// which can't reasonably be cached). Slices for pagination, returns JSON.
fn handleRecommended(request: *http.Server.Request, target: []const u8, io: Io) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const span = logfire.span("http.recommended", .{});
    defer span.end();

    const limit_str = parseQueryParam(alloc, target, "limit") catch null;
    const offset_str = parseQueryParam(alloc, target, "offset") catch null;
    const since_str = parseQueryParam(alloc, target, "since") catch null;
    const sort_str = parseQueryParam(alloc, target, "sort") catch null;
    const author_param = parseQueryParam(alloc, target, "author") catch null;
    const curator_param = parseQueryParam(alloc, target, "curator") catch null;
    const limit: usize = if (limit_str) |s| std.fmt.parseInt(usize, s, 10) catch 20 else 20;
    const offset: usize = if (offset_str) |s| std.fmt.parseInt(usize, s, 10) catch 0 else 0;
    const window = recommended.Window.fromString(since_str);
    const sort = recommended.Sort.fromString(sort_str);
    span.setAttribute("window", window.slug());
    span.setAttribute("sort", sort.slug());

    // resolve author / curator → DID (accept either form, matches search.zig's pattern)
    const resolveActor = struct {
        fn run(alloc_: std.mem.Allocator, ap_: []const u8, io_: Io) ?[]const u8 {
            if (mem.startsWith(u8, ap_, "did:")) return ap_;
            return resolveHandle(alloc_, ap_, io_) catch null;
        }
    }.run;
    const author_did: ?[]const u8 = if (author_param) |ap| resolveActor(alloc, ap, io) else null;
    const curator_did: ?[]const u8 = if (curator_param) |cp| resolveActor(alloc, cp, io) else null;
    if (author_did) |d| span.setAttribute("author", d);
    if (curator_did) |d| span.setAttribute("curator", d);

    // curator + author both set: curator wins (more specific intent — "what
    // has X recommended" is narrower than "what has Y written"). Avoids
    // surprising empty results from intersecting two filters.
    const filter: recommended.Filter = .{
        .author_did = if (curator_did != null) null else author_did,
        .curator_did = curator_did,
    };

    var body: []u8 = undefined;
    if (filter.author_did != null or filter.curator_did != null) {
        // filtered queries bypass the cache — narrow scope means sub-100ms
        // Turso turnaround, and per-(filter, window, sort) cache slots
        // would explode the working set.
        span.setAttribute("cache", "bypass");
        body = try alloc.dupe(u8, try recommended.fetch(alloc, window, sort, filter));
    } else {
        var snapshot = try recommended.snapshot(sort, window, alloc);
        if (snapshot != null) {
            span.setAttribute("cache", "hit");
        } else {
            // cold fallback — refresh thread hasn't populated this slot yet.
            span.setAttribute("cache", "cold");
            snapshot = try alloc.dupe(u8, try recommended.fetch(alloc, window, sort, .{}));
        }
        body = snapshot.?;
    }

    const sliced = try recommended.sliceJson(alloc, body, limit, offset);
    try sendJson(request, sliced);
}

/// /recommended-by-top-authors — what have the network's top-N writers
/// (by all-time recommends received) themselves recommended in `since=`?
/// A transitive-taste signal distinct from raw popularity. Tunable resolution
/// via `pool=` (how many authors form the taste-pool — small = sharp focal,
/// large = broader consensus) and `since=` (day/week/month/year/all).
fn handleRecommendedByTopAuthors(request: *http.Server.Request, target: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const span = logfire.span("http.recommended_by_top_authors", .{});
    defer span.end();

    const limit_str = parseQueryParam(alloc, target, "limit") catch null;
    const offset_str = parseQueryParam(alloc, target, "offset") catch null;
    const since_str = parseQueryParam(alloc, target, "since") catch null;
    const pool_str = parseQueryParam(alloc, target, "pool") catch null;
    const limit: usize = if (limit_str) |s| std.fmt.parseInt(usize, s, 10) catch 10 else 10;
    const offset: usize = if (offset_str) |s| std.fmt.parseInt(usize, s, 10) catch 0 else 0;
    const window = recommended.Window.fromString(since_str);
    // Clamp pool to a sane range. <1 is meaningless; >500 is wider than the
    // active recommender set and just slows things down for no signal change.
    const pool_raw: i64 = if (pool_str) |s| std.fmt.parseInt(i64, s, 10) catch 10 else 10;
    const pool: i64 = @max(1, @min(500, pool_raw));
    span.setAttribute("window", window.slug());
    span.setAttribute("pool", pool);

    const body = try recommended.fetchTopAuthorCascade(alloc, window, pool);
    const sliced = try recommended.sliceJson(alloc, body, limit, offset);
    try sendJson(request, sliced);
}

/// /curators — leaderboard of recommenders (DIDs), windowed by `since=`.
/// Same cache + slice + cold-fallback shape as /recommended, minus the
/// sort + author dimensions (curators has one natural metric).
fn handleCurators(request: *http.Server.Request, target: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const span = logfire.span("http.curators", .{});
    defer span.end();

    const limit_str = parseQueryParam(alloc, target, "limit") catch null;
    const offset_str = parseQueryParam(alloc, target, "offset") catch null;
    const since_str = parseQueryParam(alloc, target, "since") catch null;
    const limit: usize = if (limit_str) |s| std.fmt.parseInt(usize, s, 10) catch 20 else 20;
    const offset: usize = if (offset_str) |s| std.fmt.parseInt(usize, s, 10) catch 0 else 0;
    const window = recommended.Window.fromString(since_str);
    span.setAttribute("window", window.slug());

    var snapshot = try curators.Cache.snapshot(window, alloc);
    if (snapshot != null) {
        span.setAttribute("cache", "hit");
    } else {
        span.setAttribute("cache", "cold");
        snapshot = try alloc.dupe(u8, try curators.fetch(alloc, window));
    }

    const sliced = try curators.sliceJson(alloc, snapshot.?, limit, offset);
    try sendJson(request, sliced);
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

/// On-demand backfill of a single repo, bypassing tap's serial resync queue.
/// `POST /admin/backfill?did=<did>[&collection=<nsid>]`. Pulls every record of
/// our collections straight from the author's PDS through the normal
/// extract+index path. Guarded by BACKFILL_TOKEN (?token=) when that env is set.
fn handleBackfill(request: *http.Server.Request, target: []const u8, io: Io) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    if (std.c.getenv("BACKFILL_TOKEN")) |tok_c| {
        const expected = std.mem.span(tok_c);
        const provided = parseQueryParam(alloc, target, "token") catch "";
        if (!mem.eql(u8, provided, expected)) {
            try request.respond("{\"error\":\"unauthorized\"}", .{
                .status = .unauthorized,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
    }

    const did = parseQueryParam(alloc, target, "did") catch {
        try request.respond("{\"error\":\"missing did param\"}", .{
            .status = .bad_request,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
        return;
    };
    const collection: ?[]const u8 = parseQueryParam(alloc, target, "collection") catch null;

    const counts = ingest.tap.backfillRepo(alloc, io, did, collection) catch |err| {
        const body = try std.fmt.allocPrint(alloc, "{{\"error\":\"backfill failed: {s}\"}}", .{@errorName(err)});
        try request.respond(body, .{
            .status = .internal_server_error,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
        return;
    };

    const body = try std.fmt.allocPrint(alloc,
        "{{\"did\":\"{s}\",\"documents\":{d},\"publications\":{d},\"recommends\":{d},\"skipped\":{d}}}",
        .{ did, counts.documents, counts.publications, counts.recommends, counts.skipped },
    );
    try sendJson(request, body);
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

    const field_str = parseQueryParam(alloc, target, "field") catch "indexed";
    const field = dashboard.TimelineField.fromString(field_str);

    const json_response = dashboard.fetchTimeline(alloc, range, field) catch {
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
    return if (std.c.getenv("DASHBOARD_URL")) |p| std.mem.span(p) else "https://pub-search.waow.tech/stats";
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
