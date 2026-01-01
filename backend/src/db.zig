const std = @import("std");
const mem = std.mem;
const json = std.json;
const http = std.http;
const Allocator = mem.Allocator;

const URL_BUF_SIZE = 512;
const AUTH_BUF_SIZE = 512;

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};

// initialized by init(), null until then
var turso_url: ?[]const u8 = null;
var turso_token: ?[]const u8 = null;
var mutex: std.Thread.Mutex = .{};

pub fn init() !void {
    turso_url = std.posix.getenv("TURSO_URL") orelse {
        std.debug.print("TURSO_URL not set\n", .{});
        return error.MissingEnv;
    };
    turso_token = std.posix.getenv("TURSO_TOKEN") orelse {
        std.debug.print("TURSO_TOKEN not set\n", .{});
        return error.MissingEnv;
    };

    std.debug.print("using turso database: {s}\n", .{turso_url.?});
    try initSchema();
}

fn initSchema() !void {
    _ = try execSql(
        \\CREATE TABLE IF NOT EXISTS documents (
        \\  uri TEXT PRIMARY KEY,
        \\  did TEXT NOT NULL,
        \\  rkey TEXT NOT NULL,
        \\  title TEXT NOT NULL,
        \\  content TEXT NOT NULL,
        \\  created_at TEXT,
        \\  publication_uri TEXT
        \\)
    , &.{});

    _ = try execSql(
        \\CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(
        \\  uri UNINDEXED,
        \\  title,
        \\  content
        \\)
    , &.{});

    _ = try execSql(
        \\CREATE TABLE IF NOT EXISTS publications (
        \\  uri TEXT PRIMARY KEY,
        \\  did TEXT NOT NULL,
        \\  rkey TEXT NOT NULL,
        \\  name TEXT NOT NULL,
        \\  description TEXT,
        \\  base_path TEXT
        \\)
    , &.{});

    _ = try execSql(
        \\CREATE TABLE IF NOT EXISTS document_tags (
        \\  document_uri TEXT NOT NULL,
        \\  tag TEXT NOT NULL,
        \\  PRIMARY KEY (document_uri, tag)
        \\)
    , &.{});

    _ = execSql("CREATE INDEX IF NOT EXISTS idx_document_tags_tag ON document_tags(tag)", &.{}) catch |err| {
        std.debug.print("create index error: {}\n", .{err});
    };

    // migrate: add columns if missing (ignore "duplicate column" errors)
    _ = execSql("ALTER TABLE documents ADD COLUMN publication_uri TEXT", &.{}) catch |err| {
        std.debug.print("migrate documents: {}\n", .{err});
    };
    _ = execSql("ALTER TABLE publications ADD COLUMN base_path TEXT", &.{}) catch |err| {
        std.debug.print("migrate publications: {}\n", .{err});
    };

    std.debug.print("turso schema initialized with FTS5\n", .{});
}

pub fn insertDocument(uri: []const u8, did: []const u8, rkey: []const u8, title: []const u8, content: []const u8, created_at: ?[]const u8, publication_uri: ?[]const u8, tags: []const []const u8) !void {
    _ = try execSql(
        "INSERT OR REPLACE INTO documents (uri, did, rkey, title, content, created_at, publication_uri) VALUES (?, ?, ?, ?, ?, ?, ?)",
        &.{ uri, did, rkey, title, content, created_at orelse "", publication_uri orelse "" },
    );

    // update FTS index - delete old entry first, then insert new
    _ = execSql("DELETE FROM documents_fts WHERE uri = ?", &.{uri}) catch |err| {
        std.debug.print("delete FTS error for {s}: {}\n", .{ uri, err });
    };

    _ = execSql(
        "INSERT INTO documents_fts (uri, title, content) VALUES (?, ?, ?)",
        &.{ uri, title, content },
    ) catch |err| {
        std.debug.print("insert FTS error for {s}: {}\n", .{ uri, err });
    };

    // update tags - delete old, insert new
    _ = execSql("DELETE FROM document_tags WHERE document_uri = ?", &.{uri}) catch |err| {
        std.debug.print("delete tags error for {s}: {}\n", .{ uri, err });
    };
    for (tags) |tag| {
        _ = execSql(
            "INSERT OR IGNORE INTO document_tags (document_uri, tag) VALUES (?, ?)",
            &.{ uri, tag },
        ) catch |err| {
            std.debug.print("insert tag error for {s}: {}\n", .{ uri, err });
        };
    }
}

pub fn insertPublication(uri: []const u8, did: []const u8, rkey: []const u8, name: []const u8, description: ?[]const u8, base_path: ?[]const u8) !void {
    _ = try execSql(
        "INSERT OR REPLACE INTO publications (uri, did, rkey, name, description, base_path) VALUES (?, ?, ?, ?, ?, ?)",
        &.{ uri, did, rkey, name, description orelse "", base_path orelse "" },
    );
}

pub fn deleteDocument(uri: []const u8) void {
    _ = execSql("DELETE FROM documents WHERE uri = ?", &.{uri}) catch |err| {
        std.debug.print("delete document error for {s}: {}\n", .{ uri, err });
    };
    _ = execSql("DELETE FROM documents_fts WHERE uri = ?", &.{uri}) catch |err| {
        std.debug.print("delete document FTS error for {s}: {}\n", .{ uri, err });
    };
}

pub fn deletePublication(uri: []const u8) void {
    _ = execSql("DELETE FROM publications WHERE uri = ?", &.{uri}) catch |err| {
        std.debug.print("delete publication error for {s}: {}\n", .{ uri, err });
    };
}

// column indices for search query results
const SearchCol = struct {
    const uri = 0;
    const did = 1;
    const title = 2;
    const snippet = 3;
    const created_at = 4;
    const rkey = 5;
    const base_path = 6;
    const count = 7;
};

pub fn searchDocuments(alloc: Allocator, query: []const u8, tag_filter: ?[]const u8) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    const temp_alloc = gpa.allocator();

    // normalize query to match FTS5 tokenization (dots become spaces)
    const normalized_query = try alloc.dupe(u8, query);
    for (normalized_query) |*c| {
        if (c.* == '.') c.* = ' ';
    }

    // build query based on whether we have a tag filter
    const result = if (tag_filter) |tag|
        execSql(
            \\SELECT f.uri, d.did, d.title,
            \\  snippet(documents_fts, 2, '<mark>', '</mark>', '...', 32) as snippet,
            \\  d.created_at, d.rkey, p.base_path
            \\FROM documents_fts f
            \\JOIN documents d ON f.uri = d.uri
            \\LEFT JOIN publications p ON d.publication_uri = p.uri
            \\JOIN document_tags dt ON d.uri = dt.document_uri
            \\WHERE documents_fts MATCH ? AND dt.tag = ?
            \\ORDER BY rank LIMIT 50
        , &.{ normalized_query, tag }) catch {
            try output.writer.writeAll("[]");
            return try output.toOwnedSlice();
        }
    else
        execSql(
            \\SELECT f.uri, d.did, d.title,
            \\  snippet(documents_fts, 2, '<mark>', '</mark>', '...', 32) as snippet,
            \\  d.created_at, d.rkey, p.base_path
            \\FROM documents_fts f
            \\JOIN documents d ON f.uri = d.uri
            \\LEFT JOIN publications p ON d.publication_uri = p.uri
            \\WHERE documents_fts MATCH ?
            \\ORDER BY rank LIMIT 50
        , &.{normalized_query}) catch {
            try output.writer.writeAll("[]");
            return try output.toOwnedSlice();
        };
    defer temp_alloc.free(result);

    // parse JSON response - keep parsed alive while iterating rows
    const parsed = json.parseFromSlice(json.Value, temp_alloc, result, .{}) catch {
        try output.writer.writeAll("[]");
        return try output.toOwnedSlice();
    };
    defer parsed.deinit();

    const rows = getRowsFromParsed(parsed.value) orelse {
        try output.writer.writeAll("[]");
        return try output.toOwnedSlice();
    };

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();

    for (rows.items) |row| {
        if (row != .array or row.array.items.len < SearchCol.count) continue;
        const cols = row.array.items;

        try jw.beginObject();
        try jw.objectField("uri");
        try jw.write(extractText(cols[SearchCol.uri]));
        try jw.objectField("did");
        try jw.write(extractText(cols[SearchCol.did]));
        try jw.objectField("title");
        try jw.write(extractText(cols[SearchCol.title]));
        try jw.objectField("snippet");
        try jw.write(extractText(cols[SearchCol.snippet]));
        try jw.objectField("createdAt");
        try jw.write(extractText(cols[SearchCol.created_at]));
        try jw.objectField("rkey");
        try jw.write(extractText(cols[SearchCol.rkey]));
        try jw.objectField("basePath");
        try jw.write(extractText(cols[SearchCol.base_path]));
        try jw.endObject();
    }

    try jw.endArray();
    return try output.toOwnedSlice();
}

fn getRowsFromParsed(value: json.Value) ?json.Array {
    const results = value.object.get("results") orelse return null;
    if (results != .array or results.array.items.len == 0) return null;

    const first = results.array.items[0];
    if (first != .object) return null;

    const resp = first.object.get("response") orelse return null;
    if (resp != .object) return null;

    const res = resp.object.get("result") orelse return null;
    if (res != .object) return null;

    const rows = res.object.get("rows") orelse return null;
    if (rows != .array) return null;

    return rows.array;
}

fn extractText(val: json.Value) []const u8 {
    return switch (val) {
        .string => |s| s,
        .object => |obj| if (obj.get("value")) |v| (if (v == .string) v.string else "") else "",
        else => "",
    };
}

fn execSql(sql: []const u8, args: []const []const u8) ![]const u8 {
    mutex.lock();
    defer mutex.unlock();

    const alloc = gpa.allocator();

    const url_value = turso_url orelse return error.NotInitialized;
    const token_value = turso_token orelse return error.NotInitialized;

    // strip libsql:// prefix if present, use https://
    const libsql_prefix = "libsql://";
    const host = if (mem.startsWith(u8, url_value, libsql_prefix))
        url_value[libsql_prefix.len..]
    else
        url_value;

    var url_buf: [URL_BUF_SIZE]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://{s}/v2/pipeline", .{host}) catch return error.UrlTooLong;

    // build request body
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();

    var jw: json.Stringify = .{ .writer = &body.writer };
    try jw.beginObject();
    try jw.objectField("requests");
    try jw.beginArray();

    // execute statement
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("execute");
    try jw.objectField("stmt");
    try jw.beginObject();
    try jw.objectField("sql");
    try jw.write(sql);
    if (args.len > 0) {
        try jw.objectField("args");
        try jw.beginArray();
        for (args) |arg| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("text");
            try jw.objectField("value");
            try jw.write(arg);
            try jw.endObject();
        }
        try jw.endArray();
    }
    try jw.endObject();
    try jw.endObject();

    // close statement
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("close");
    try jw.endObject();

    try jw.endArray();
    try jw.endObject();

    var auth_buf: [AUTH_BUF_SIZE]u8 = undefined;
    const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token_value}) catch return error.AuthTooLong;

    var client: http.Client = .{ .allocator = alloc };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(alloc);
    defer response_body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = auth_header },
        },
        .payload = body.written(),
        .response_writer = &response_body.writer,
    }) catch |err| {
        std.debug.print("turso request failed: {}\n", .{err});
        return error.HttpError;
    };

    if (result.status != .ok) {
        std.debug.print("turso error: {}\n", .{result.status});
        return error.TursoError;
    }

    return try response_body.toOwnedSlice();
}

pub fn getTags(alloc: Allocator) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    const temp_alloc = gpa.allocator();

    const result = execSql(
        \\SELECT tag, COUNT(*) as count
        \\FROM document_tags
        \\GROUP BY tag
        \\ORDER BY count DESC
        \\LIMIT 100
    , &.{}) catch {
        try output.writer.writeAll("[]");
        return try output.toOwnedSlice();
    };
    defer temp_alloc.free(result);

    const parsed = json.parseFromSlice(json.Value, temp_alloc, result, .{}) catch {
        try output.writer.writeAll("[]");
        return try output.toOwnedSlice();
    };
    defer parsed.deinit();

    const rows = getRowsFromParsed(parsed.value) orelse {
        try output.writer.writeAll("[]");
        return try output.toOwnedSlice();
    };

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();

    for (rows.items) |row| {
        if (row != .array or row.array.items.len < 2) continue;
        const cols = row.array.items;

        try jw.beginObject();
        try jw.objectField("tag");
        try jw.write(extractText(cols[0]));
        try jw.objectField("count");
        const count_val = cols[1];
        const count: i64 = switch (count_val) {
            .integer => |i| i,
            .object => |obj| blk: {
                const v = obj.get("value") orelse break :blk 0;
                break :blk switch (v) {
                    .integer => |i| i,
                    .string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
                    else => 0,
                };
            },
            else => 0,
        };
        try jw.write(count);
        try jw.endObject();
    }

    try jw.endArray();
    return try output.toOwnedSlice();
}

pub fn getStats() struct { documents: i64, publications: i64 } {
    const doc_result = execSql("SELECT COUNT(*) FROM documents", &.{}) catch return .{ .documents = 0, .publications = 0 };
    defer gpa.allocator().free(doc_result);

    const pub_result = execSql("SELECT COUNT(*) FROM publications", &.{}) catch return .{ .documents = 0, .publications = 0 };
    defer gpa.allocator().free(pub_result);

    return .{
        .documents = parseCount(doc_result),
        .publications = parseCount(pub_result),
    };
}

fn parseCount(result: []const u8) i64 {
    const alloc = gpa.allocator();
    const parsed = json.parseFromSlice(json.Value, alloc, result, .{}) catch return 0;
    defer parsed.deinit();

    const rows = getRowsFromParsed(parsed.value) orelse return 0;
    if (rows.items.len == 0) return 0;

    const first_row = rows.items[0];
    if (first_row != .array or first_row.array.items.len == 0) return 0;

    const val = first_row.array.items[0];
    return switch (val) {
        .integer => |i| i,
        .object => |obj| blk: {
            const v = obj.get("value") orelse break :blk 0;
            break :blk switch (v) {
                .integer => |i| i,
                .string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
                else => 0,
            };
        },
        else => 0,
    };
}
