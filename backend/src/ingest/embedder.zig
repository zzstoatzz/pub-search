//! Background worker for generating document embeddings via Voyage AI.
//!
//! Periodically queries for documents missing embeddings, batches them,
//! calls the Voyage API, and updates Turso with the results.

const std = @import("std");
const http = std.http;
const json = std.json;
const mem = std.mem;
const posix = std.posix;
const Allocator = mem.Allocator;
const logfire = @import("logfire");
const db = @import("../db/mod.zig");

// voyage-3-lite limits
const MAX_BATCH_SIZE = 20; // conservative batch size for reliability
const MAX_CONTENT_CHARS = 8000; // ~2000 tokens, well under 32K limit
const EMBEDDING_DIM = 512;
const POLL_INTERVAL_SECS: u64 = 60; // check for new docs every minute
const ERROR_BACKOFF_SECS: u64 = 300; // 5 min backoff on errors

/// Start the embedder background worker
pub fn start(allocator: Allocator) void {
    const api_key = posix.getenv("VOYAGE_API_KEY") orelse {
        logfire.info("embedder: VOYAGE_API_KEY not set, embeddings disabled", .{});
        return;
    };

    const thread = std.Thread.spawn(.{}, worker, .{ allocator, api_key }) catch |err| {
        logfire.err("embedder: failed to start thread: {}", .{err});
        return;
    };
    thread.detach();
    logfire.info("embedder: background worker started", .{});
}

fn worker(allocator: Allocator, api_key: []const u8) void {
    // wait for db to be ready
    std.Thread.sleep(5 * std.time.ns_per_s);

    var consecutive_errors: u32 = 0;

    while (true) {
        const processed = processNextBatch(allocator, api_key) catch |err| {
            consecutive_errors += 1;
            const backoff: u64 = @min(ERROR_BACKOFF_SECS * consecutive_errors, 3600);
            logfire.warn("embedder: error {}, backing off {d}s", .{ err, backoff });
            std.Thread.sleep(backoff * std.time.ns_per_s);
            continue;
        };

        if (processed > 0) {
            consecutive_errors = 0;
            logfire.counter("embedder.documents_processed", @intCast(processed));
            // immediately check for more
            continue;
        }

        // no work, sleep
        consecutive_errors = 0;
        std.Thread.sleep(POLL_INTERVAL_SECS * std.time.ns_per_s);
    }
}

const DocToEmbed = struct {
    uri: []const u8,
    text: []const u8, // title + " " + content (truncated)
};

fn processNextBatch(allocator: Allocator, api_key: []const u8) !usize {
    const span = logfire.span("embedder.process_batch", .{});
    defer span.end();

    const client = db.getClient() orelse return error.NoClient;

    // query for documents needing embeddings
    var result = try client.query(
        "SELECT uri, title, content FROM documents WHERE embedding IS NULL LIMIT ?",
        &.{std.fmt.comptimePrint("{}", .{MAX_BATCH_SIZE})},
    );
    defer result.deinit();

    // collect documents
    var docs: std.ArrayList(DocToEmbed) = .empty;
    defer {
        for (docs.items) |doc| {
            allocator.free(doc.text);
        }
        docs.deinit(allocator);
    }

    for (result.rows) |row| {
        const uri = row.text(0);
        const title = row.text(1);
        const content = row.text(2);

        // build text for embedding: title + content, truncated
        const text = try buildEmbeddingText(allocator, title, content);
        try docs.append(allocator, .{ .uri = uri, .text = text });
    }

    if (docs.items.len == 0) return 0;

    // call Voyage API
    const embeddings = try callVoyageApi(allocator, api_key, docs.items);
    defer {
        for (embeddings) |e| allocator.free(e);
        allocator.free(embeddings);
    }

    // update Turso with embeddings
    for (docs.items, embeddings) |doc, embedding| {
        updateDocumentEmbedding(client, doc.uri, embedding) catch |err| {
            logfire.err("embedder: failed to update {s}: {}", .{ doc.uri, err });
        };
    }

    return docs.items.len;
}

fn buildEmbeddingText(allocator: Allocator, title: []const u8, content: []const u8) ![]u8 {
    // truncate content if needed
    const max_content = MAX_CONTENT_CHARS -| title.len -| 1;
    const truncated_content = if (content.len > max_content) content[0..max_content] else content;

    const text = try allocator.alloc(u8, title.len + 1 + truncated_content.len);
    @memcpy(text[0..title.len], title);
    text[title.len] = ' ';
    @memcpy(text[title.len + 1 ..], truncated_content);

    // sanitize to valid UTF-8 (replace invalid bytes with space)
    // this ensures json.Stringify treats it as a string, not byte array
    sanitizeUtf8(text);

    return text;
}

fn sanitizeUtf8(text: []u8) void {
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            text[i] = ' '; // replace invalid start byte
            i += 1;
            continue;
        };
        if (i + len > text.len) {
            // truncated sequence at end
            text[i] = ' ';
            i += 1;
            continue;
        }
        // validate the full sequence
        _ = std.unicode.utf8Decode(text[i..][0..len]) catch {
            text[i] = ' '; // replace invalid sequence start
            i += 1;
            continue;
        };
        i += len;
    }
}

fn callVoyageApi(allocator: Allocator, api_key: []const u8, docs: []const DocToEmbed) ![][]f32 {
    const span = logfire.span("embedder.voyage_api", .{
        .batch_size = @as(i64, @intCast(docs.len)),
    });
    defer span.end();

    var http_client: http.Client = .{ .allocator = allocator };
    defer http_client.deinit();

    // build request body
    const body = try buildVoyageRequest(allocator, docs);
    defer allocator.free(body);

    // prepare auth header
    var auth_buf: [256]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{api_key}) catch
        return error.AuthTooLong;

    // make request
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
        logfire.err("embedder: voyage request failed: {}", .{err});
        return error.VoyageRequestFailed;
    };

    if (res.status != .ok) {
        const resp_text = response_body.toOwnedSlice() catch "";
        defer if (resp_text.len > 0) allocator.free(resp_text);
        logfire.err("embedder: voyage error {}: {s}", .{ res.status, resp_text[0..@min(resp_text.len, 200)] });
        return error.VoyageApiError;
    }

    const response_text = try response_body.toOwnedSlice();
    defer allocator.free(response_text);

    return parseVoyageResponse(allocator, response_text, docs.len);
}

fn buildVoyageRequest(allocator: Allocator, docs: []const DocToEmbed) ![]const u8 {
    var body: std.Io.Writer.Allocating = .init(allocator);
    errdefer body.deinit();
    var jw: json.Stringify = .{ .writer = &body.writer, .options = .{} };

    try jw.beginObject();

    try jw.objectField("model");
    try jw.write("voyage-3-lite");

    try jw.objectField("input_type");
    try jw.write("document");

    try jw.objectField("input");
    try jw.beginArray();
    for (docs) |doc| {
        try jw.write(doc.text);
    }
    try jw.endArray();

    try jw.endObject();

    return try body.toOwnedSlice();
}

fn parseVoyageResponse(allocator: Allocator, response: []const u8, expected_count: usize) ![][]f32 {
    const parsed = json.parseFromSlice(json.Value, allocator, response, .{}) catch {
        logfire.err("embedder: failed to parse voyage response", .{});
        return error.ParseError;
    };
    defer parsed.deinit();

    const data = parsed.value.object.get("data") orelse return error.MissingData;
    if (data != .array) return error.InvalidData;

    if (data.array.items.len != expected_count) {
        logfire.err("embedder: expected {d} embeddings, got {d}", .{ expected_count, data.array.items.len });
        return error.CountMismatch;
    }

    const embeddings = try allocator.alloc([]f32, expected_count);
    errdefer {
        for (embeddings) |e| allocator.free(e);
        allocator.free(embeddings);
    }

    for (data.array.items, 0..) |item, i| {
        const embedding_val = item.object.get("embedding") orelse return error.MissingEmbedding;
        if (embedding_val != .array) return error.InvalidEmbedding;

        const embedding = try allocator.alloc(f32, EMBEDDING_DIM);
        errdefer allocator.free(embedding);

        if (embedding_val.array.items.len != EMBEDDING_DIM) {
            std.debug.print("embedder: expected {} dims, got {}\n", .{ EMBEDDING_DIM, embedding_val.array.items.len });
            return error.DimensionMismatch;
        }

        for (embedding_val.array.items, 0..) |val, j| {
            embedding[j] = switch (val) {
                .float => @floatCast(val.float),
                .integer => @floatFromInt(val.integer),
                else => return error.InvalidValue,
            };
        }
        embeddings[i] = embedding;
    }

    return embeddings;
}

fn updateDocumentEmbedding(client: *db.Client, uri: []const u8, embedding: []f32) !void {
    const allocator = client.allocator;

    // serialize embedding to JSON array string for vector32()
    var embedding_json: std.ArrayList(u8) = .empty;
    defer embedding_json.deinit(allocator);

    try embedding_json.append(allocator, '[');
    for (embedding, 0..) |val, i| {
        if (i > 0) try embedding_json.append(allocator, ',');
        var buf: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d:.6}", .{val}) catch continue;
        try embedding_json.appendSlice(allocator, str);
    }
    try embedding_json.append(allocator, ']');

    // use batch API to execute dynamic SQL
    const statements = [_]db.Client.Statement{
        .{
            .sql = "UPDATE documents SET embedding = vector32(?) WHERE uri = ?",
            .args = &.{ embedding_json.items, uri },
        },
    };

    var result = client.queryBatch(&statements) catch |err| {
        std.debug.print("embedder: update failed for {s}: {}\n", .{ uri, err });
        return err;
    };
    defer result.deinit();
}
