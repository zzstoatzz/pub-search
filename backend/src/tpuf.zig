//! Turbopuffer vector store client.
//!
//! Manages vector upserts and ANN queries against a turbopuffer namespace.
//! Used by:
//!   - ingest/embedder.zig: upsert document vectors after embedding
//!   - search.zig: ANN query for semantic search + /similar replacement
//!
//! All operations are fire-and-forget safe — callers should handle errors
//! gracefully since the system works without vector search.

const std = @import("std");
const json = std.json;
const http = std.http;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const logfire = @import("logfire");

var global_io: ?Io = null;

const Sha256 = std.crypto.hash.sha2.Sha256;

const API_BASE = "https://api.turbopuffer.com/v2/namespaces/";

var api_key: ?[]const u8 = null;
var voyage_api_key: ?[]const u8 = null;
var namespace: []const u8 = "leaflet-search";

// pre-formatted URL paths (built at init)
var upsert_url_buf: [256]u8 = undefined;
var upsert_url: []const u8 = "";
var query_url_buf: [256]u8 = undefined;
var query_url: []const u8 = "";

/// Document metadata stored alongside vectors in turbopuffer.
/// Fields mirror the SearchResultJson output so query results
/// can be returned directly without a DB roundtrip.
pub const VectorDoc = struct {
    id: []const u8, // hashed ID for tpuf (via hashId)
    vector: []const f32, // embedding (voyage-4-lite, 1024 dims)
    uri: []const u8, // full AT-URI (stored as metadata)
    title: []const u8,
    did: []const u8,
    created_at: []const u8,
    rkey: []const u8,
    base_path: []const u8,
    platform: []const u8,
    path: []const u8,
    has_publication: bool,
};

/// Result from an ANN query.
pub const QueryResult = struct {
    id: []const u8,
    dist: f64,
    uri: []const u8,
    title: []const u8,
    did: []const u8,
    created_at: []const u8,
    rkey: []const u8,
    base_path: []const u8,
    platform: []const u8,
    path: []const u8,
    has_publication: bool,
};

/// Read config from environment. Call once at startup.
pub fn init(io: Io) void {
    global_io = io;
    api_key = if (std.c.getenv("TURBOPUFFER_API_KEY")) |p| std.mem.span(p) else null;
    if (if (std.c.getenv("TURBOPUFFER_NAMESPACE")) |p| std.mem.span(p) else null) |ns| {
        namespace = ns;
    }

    if (api_key != null) {
        // pre-format URL paths
        upsert_url = std.fmt.bufPrint(&upsert_url_buf, "{s}{s}", .{ API_BASE, namespace }) catch {
            logfire.err("tpuf: namespace too long", .{});
            api_key = null;
            return;
        };
        query_url = std.fmt.bufPrint(&query_url_buf, "{s}{s}/query", .{ API_BASE, namespace }) catch {
            logfire.err("tpuf: namespace too long", .{});
            api_key = null;
            return;
        };
        logfire.info("tpuf: initialized (namespace={s})", .{namespace});
    } else {
        logfire.info("tpuf: TURBOPUFFER_API_KEY not set, vector store disabled", .{});
    }

    voyage_api_key = if (std.c.getenv("VOYAGE_API_KEY")) |p| std.mem.span(p) else null;
    if (voyage_api_key != null) {
        logfire.info("tpuf: voyage query embedding enabled", .{});
    }
}

pub fn isEnabled() bool {
    return api_key != null;
}

pub fn isSemanticEnabled() bool {
    return api_key != null and voyage_api_key != null;
}

/// Embed a search query via Voyage API (input_type="query" for asymmetric search).
/// Returns a 1024-dim f32 vector. Caller owns the returned slice.
pub fn embedQuery(allocator: Allocator, text: []const u8) ![]f32 {
    const vk = voyage_api_key orelse return error.NotConfigured;

    const span = logfire.span("tpuf.embed_query", .{});
    defer span.end();

    // build request body
    var body_buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer body_buf.deinit();

    var jw: json.Stringify = .{ .writer = &body_buf.writer };
    try jw.beginObject();
    try jw.objectField("model");
    try jw.write("voyage-4-lite");
    try jw.objectField("input_type");
    try jw.write("query");
    try jw.objectField("output_dimension");
    try jw.write(1024);
    try jw.objectField("input");
    try jw.beginArray();
    try jw.write(text);
    try jw.endArray();
    try jw.endObject();

    const body = try body_buf.toOwnedSlice();
    defer allocator.free(body);

    // make request
    var http_client: http.Client = .{ .allocator = allocator, .io = global_io.? };
    defer http_client.deinit();

    var auth_buf: [256]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{vk}) catch
        return error.AuthTooLong;

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    errdefer response_body.deinit();

    const res = http_client.fetch(.{
        .location = .{ .url = "https://api.voyageai.com/v1/embeddings" },
        .method = .POST,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = auth },
        },
        .payload = body,
        .response_writer = &response_body.writer,
    }) catch |err| {
        logfire.err("tpuf: voyage embed_query failed: {}", .{err});
        return error.RequestFailed;
    };

    if (res.status != .ok) {
        const resp_text = response_body.toOwnedSlice() catch "";
        defer if (resp_text.len > 0) allocator.free(resp_text);
        logfire.err("tpuf: voyage embed_query error {}: {s}", .{ res.status, resp_text[0..@min(resp_text.len, 200)] });
        return error.ApiError;
    }

    const response_text = try response_body.toOwnedSlice();
    defer allocator.free(response_text);

    // parse data[0].embedding
    const parsed = json.parseFromSlice(json.Value, allocator, response_text, .{}) catch {
        logfire.err("tpuf: failed to parse voyage response", .{});
        return error.ParseError;
    };
    defer parsed.deinit();

    const data = parsed.value.object.get("data") orelse return error.ParseError;
    if (data != .array or data.array.items.len == 0) return error.ParseError;

    const embedding_val = data.array.items[0].object.get("embedding") orelse return error.ParseError;
    if (embedding_val != .array) return error.ParseError;

    const dims = embedding_val.array.items;
    const vector = try allocator.alloc(f32, dims.len);
    errdefer allocator.free(vector);

    for (dims, 0..) |val, i| {
        vector[i] = switch (val) {
            .float => @floatCast(val.float),
            .integer => @floatFromInt(val.integer),
            else => return error.ParseError,
        };
    }

    return vector;
}

/// Hash a URI to a tpuf-safe ID (max 64 bytes).
/// Uses first 32 hex chars of SHA256 (128 bits — no collisions at our scale).
pub fn hashId(uri: []const u8) [32]u8 {
    const hex_chars = "0123456789abcdef";
    var digest: [32]u8 = undefined;
    Sha256.hash(uri, &digest, .{});
    var hex: [32]u8 = undefined;
    for (digest[0..16], 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0xf];
    }
    return hex;
}

/// Upsert document vectors with metadata. Creates the namespace on first write.
/// Errors are logged but should not be fatal — the system works without vector search.
pub fn upsert(allocator: Allocator, docs: []const VectorDoc) !void {
    const key = api_key orelse return error.NotConfigured;
    if (docs.len == 0) return;

    const span = logfire.span("tpuf.upsert", .{
        .count = @as(i64, @intCast(docs.len)),
    });
    defer span.end();

    const body = try buildUpsertBody(allocator, docs);
    defer allocator.free(body);

    const response = try doRequest(allocator, key, upsert_url, body);
    defer allocator.free(response);
}

/// ANN query: find the top_k most similar vectors to the given query vector.
/// Returns results with full document metadata for direct use in search responses.
pub fn query(allocator: Allocator, vector: []const f32, top_k: usize) ![]QueryResult {
    const key = api_key orelse return error.NotConfigured;

    const span = logfire.span("tpuf.query", .{
        .top_k = @as(i64, @intCast(top_k)),
    });
    defer span.end();

    const body = try buildQueryBody(allocator, vector, top_k);
    defer allocator.free(body);

    const response = try doRequest(allocator, key, query_url, body);
    defer allocator.free(response);

    return parseQueryResponse(allocator, response);
}

/// Retrieve a document's vector by its ID (AT-URI).
/// Used to get the source vector for ANN similarity queries.
pub fn getVectorById(allocator: Allocator, id: []const u8) ![]f32 {
    const key = api_key orelse return error.NotConfigured;

    const span = logfire.span("tpuf.get_vector", .{});
    defer span.end();

    const body = try buildGetVectorBody(allocator, id);
    defer allocator.free(body);

    const response = try doRequest(allocator, key, query_url, body);
    defer allocator.free(response);

    return parseVectorResponse(allocator, response);
}

/// Delete vectors by ID. Can be batched into a single write call.
pub fn delete(allocator: Allocator, ids: []const []const u8) !void {
    const key = api_key orelse return error.NotConfigured;
    if (ids.len == 0) return;

    const span = logfire.span("tpuf.delete", .{
        .count = @as(i64, @intCast(ids.len)),
    });
    defer span.end();

    const body = try buildDeleteBody(allocator, ids);
    defer allocator.free(body);

    const response = try doRequest(allocator, key, upsert_url, body);
    defer allocator.free(response);
}

// --- request builders ---

fn buildUpsertBody(allocator: Allocator, docs: []const VectorDoc) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginObject();

    try jw.objectField("distance_metric");
    try jw.write("cosine_distance");

    try jw.objectField("upsert_rows");
    try jw.beginArray();

    for (docs) |doc| {
        try jw.beginObject();

        try jw.objectField("id");
        try jw.write(doc.id);

        try jw.objectField("vector");
        try jw.beginArray();
        for (doc.vector) |v| try jw.write(v);
        try jw.endArray();

        try jw.objectField("uri");
        try jw.write(doc.uri);
        try jw.objectField("title");
        try jw.write(doc.title);
        try jw.objectField("did");
        try jw.write(doc.did);
        try jw.objectField("created_at");
        try jw.write(doc.created_at);
        try jw.objectField("rkey");
        try jw.write(doc.rkey);
        try jw.objectField("base_path");
        try jw.write(doc.base_path);
        try jw.objectField("platform");
        try jw.write(doc.platform);
        try jw.objectField("path");
        try jw.write(doc.path);
        try jw.objectField("has_publication");
        try jw.write(@as(u64, if (doc.has_publication) 1 else 0));

        try jw.endObject();
    }

    try jw.endArray();
    try jw.endObject();

    return try output.toOwnedSlice();
}

fn buildQueryBody(allocator: Allocator, vector: []const f32, top_k: usize) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginObject();

    // rank_by: ["vector", "ANN", [0.1, 0.2, ...]]
    try jw.objectField("rank_by");
    try jw.beginArray();
    try jw.write("vector");
    try jw.write("ANN");
    try jw.beginArray();
    for (vector) |v| try jw.write(v);
    try jw.endArray();
    try jw.endArray();

    try jw.objectField("top_k");
    try jw.write(top_k);

    try jw.objectField("include_attributes");
    try jw.beginArray();
    for ([_][]const u8{
        "uri",
        "title",
        "did",
        "created_at",
        "rkey",
        "base_path",
        "platform",
        "path",
        "has_publication",
    }) |attr| {
        try jw.write(attr);
    }
    try jw.endArray();

    try jw.endObject();

    return try output.toOwnedSlice();
}

fn buildGetVectorBody(allocator: Allocator, id: []const u8) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginObject();

    // rank_by: ["id", "asc"] — return by ID order (we only want 1)
    try jw.objectField("rank_by");
    try jw.beginArray();
    try jw.write("id");
    try jw.write("asc");
    try jw.endArray();

    // filters: ["id", "Eq", "<id>"]
    try jw.objectField("filters");
    try jw.beginArray();
    try jw.write("id");
    try jw.write("Eq");
    try jw.write(id);
    try jw.endArray();

    try jw.objectField("top_k");
    try jw.write(1);

    try jw.objectField("include_attributes");
    try jw.beginArray();
    try jw.write("vector");
    try jw.endArray();

    try jw.endObject();

    return try output.toOwnedSlice();
}

fn buildDeleteBody(allocator: Allocator, ids: []const []const u8) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginObject();

    try jw.objectField("deletes");
    try jw.beginArray();
    for (ids) |id| try jw.write(id);
    try jw.endArray();

    try jw.endObject();

    return try output.toOwnedSlice();
}

// --- response parsing ---

fn parseQueryResponse(allocator: Allocator, response: []const u8) ![]QueryResult {
    const parsed = json.parseFromSlice(json.Value, allocator, response, .{}) catch {
        logfire.err("tpuf: failed to parse query response", .{});
        return error.ParseError;
    };
    defer parsed.deinit();

    const rows = switch (parsed.value) {
        .object => |obj| obj.get("rows") orelse return &.{},
        else => return &.{},
    };

    const items = switch (rows) {
        .array => |arr| arr.items,
        else => return &.{},
    };

    if (items.len == 0) return &.{};

    var results = try allocator.alloc(QueryResult, items.len);
    var count: usize = 0;

    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        results[count] = .{
            .id = try allocator.dupe(u8, jsonStr(obj, "id")),
            .dist = jsonFloat(obj, "$dist"),
            .uri = try allocator.dupe(u8, jsonStr(obj, "uri")),
            .title = try allocator.dupe(u8, jsonStr(obj, "title")),
            .did = try allocator.dupe(u8, jsonStr(obj, "did")),
            .created_at = try allocator.dupe(u8, jsonStr(obj, "created_at")),
            .rkey = try allocator.dupe(u8, jsonStr(obj, "rkey")),
            .base_path = try allocator.dupe(u8, jsonStr(obj, "base_path")),
            .platform = try allocator.dupe(u8, jsonStr(obj, "platform")),
            .path = try allocator.dupe(u8, jsonStr(obj, "path")),
            .has_publication = jsonUint(obj, "has_publication") != 0,
        };
        count += 1;
    }

    // shrink to actual count if any rows were skipped
    if (count < items.len) {
        return allocator.realloc(results, count) catch results[0..count];
    }
    return results;
}

fn parseVectorResponse(allocator: Allocator, response: []const u8) ![]f32 {
    const parsed = json.parseFromSlice(json.Value, allocator, response, .{}) catch {
        logfire.err("tpuf: failed to parse vector response", .{});
        return error.ParseError;
    };
    defer parsed.deinit();

    const rows = switch (parsed.value) {
        .object => |obj| obj.get("rows") orelse return error.NoRows,
        else => return error.InvalidResponse,
    };

    const items = switch (rows) {
        .array => |arr| arr.items,
        else => return error.InvalidResponse,
    };

    if (items.len == 0) return error.NotFound;

    const row = switch (items[0]) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };

    const vec_val = row.get("vector") orelse return error.NoVector;
    const vec_items = switch (vec_val) {
        .array => |arr| arr.items,
        else => return error.InvalidResponse,
    };

    const vector = try allocator.alloc(f32, vec_items.len);
    errdefer allocator.free(vector);

    for (vec_items, 0..) |val, i| {
        vector[i] = switch (val) {
            .float => @floatCast(val.float),
            .integer => @floatFromInt(val.integer),
            else => return error.InvalidValue,
        };
    }

    return vector;
}

// --- JSON helpers ---

fn jsonStr(obj: json.ObjectMap, key: []const u8) []const u8 {
    const val = obj.get(key) orelse return "";
    return switch (val) {
        .string => |s| s,
        else => "",
    };
}

fn jsonFloat(obj: json.ObjectMap, key: []const u8) f64 {
    const val = obj.get(key) orelse return 0;
    return switch (val) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

fn jsonUint(obj: json.ObjectMap, key: []const u8) u64 {
    const val = obj.get(key) orelse return 0;
    return switch (val) {
        .integer => |i| @intCast(i),
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

// --- HTTP ---

fn doRequest(allocator: Allocator, key: []const u8, url: []const u8, body: []const u8) ![]const u8 {
    var client: http.Client = .{ .allocator = allocator, .io = global_io.? };
    defer client.deinit();

    var auth_buf: [256]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{key}) catch
        return error.AuthTooLong;

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    errdefer response_body.deinit();

    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = auth },
        },
        .payload = body,
        .response_writer = &response_body.writer,
    }) catch |err| {
        logfire.err("tpuf: request failed: {}", .{err});
        return error.RequestFailed;
    };

    if (res.status != .ok) {
        const resp_text = response_body.toOwnedSlice() catch "";
        defer if (resp_text.len > 0) allocator.free(resp_text);
        logfire.err("tpuf: API error {}: {s}", .{ res.status, resp_text[0..@min(resp_text.len, 200)] });
        return error.ApiError;
    }

    return try response_body.toOwnedSlice();
}

// --- keepalive ---

const KEEPALIVE_INTERVAL_NS: u64 = 3 * 60 * std.time.ns_per_s; // 3 minutes

/// Start a background thread that pings turbopuffer periodically to prevent cold starts.
/// Cold starts add ~600-900ms to the first query after inactivity.
pub fn startKeepalive(allocator: Allocator) void {
    if (api_key == null) return;
    const thread = std.Thread.spawn(.{}, keepaliveLoop, .{allocator}) catch |err| {
        logfire.warn("tpuf: failed to start keepalive thread: {}", .{err});
        return;
    };
    thread.detach();
    logfire.info("tpuf: keepalive started (interval=3m)", .{});
}

fn keepaliveLoop(allocator: Allocator) void {
    const io = global_io.?;
    // minimal query body: rank by ID, top_k=1, no attributes
    const ping_body = "{\"rank_by\":[\"id\",\"asc\"],\"top_k\":1,\"include_attributes\":[]}";
    while (true) {
        io.sleep(Io.Duration.fromNanoseconds(KEEPALIVE_INTERVAL_NS), .awake) catch {};
        const key = api_key orelse return;
        const response = doRequest(allocator, key, query_url, ping_body) catch |err| {
            logfire.debug("tpuf: keepalive ping failed: {}", .{err});
            continue;
        };
        allocator.free(response);
    }
}
