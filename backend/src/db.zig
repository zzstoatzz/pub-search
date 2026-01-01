const std = @import("std");
const mem = std.mem;
const json = std.json;
const http = std.http;
const Allocator = mem.Allocator;

pub var turso_url: []const u8 = undefined;
pub var turso_token: []const u8 = undefined;
pub var mutex: std.Thread.Mutex = .{};

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};

// Turso API response types
const TursoResponse = struct {
    results: []const TursoResult,
};

const TursoResult = struct {
    type: []const u8,
    response: ?TursoResultResponse = null,
};

const TursoResultResponse = struct {
    type: []const u8,
    result: ?TursoQueryResult = null,
};

const TursoQueryResult = struct {
    rows: []const []const TursoValue,
};

const TursoValue = struct {
    type: []const u8,
    value: ?json.Value = null,
};

// Search result type
pub const SearchResult = struct {
    uri: []const u8,
    did: []const u8,
    title: []const u8,
    snippet: []const u8,
    createdAt: []const u8,
    rkey: []const u8,
    basePath: []const u8,
};

pub fn init() !void {
    turso_url = std.posix.getenv("TURSO_URL") orelse {
        std.debug.print("TURSO_URL not set\n", .{});
        return error.MissingEnv;
    };
    turso_token = std.posix.getenv("TURSO_TOKEN") orelse {
        std.debug.print("TURSO_TOKEN not set\n", .{});
        return error.MissingEnv;
    };

    std.debug.print("using turso database: {s}\n", .{turso_url});
    try initSchema();
}

pub fn close() void {}

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

    // migrate: add columns if missing
    _ = execSql("ALTER TABLE documents ADD COLUMN publication_uri TEXT", &.{}) catch {};
    _ = execSql("ALTER TABLE publications ADD COLUMN base_path TEXT", &.{}) catch {};

    std.debug.print("turso schema initialized with FTS5\n", .{});
}

pub fn insertDocument(uri: []const u8, did: []const u8, rkey: []const u8, title: []const u8, content: []const u8, created_at: ?[]const u8, publication_uri: ?[]const u8) !void {
    _ = try execSql(
        "INSERT OR REPLACE INTO documents (uri, did, rkey, title, content, created_at, publication_uri) VALUES (?, ?, ?, ?, ?, ?, ?)",
        &.{ uri, did, rkey, title, content, created_at orelse "", publication_uri orelse "" },
    );

    _ = execSql("DELETE FROM documents_fts WHERE uri = ?", &.{uri}) catch {};

    _ = execSql(
        "INSERT INTO documents_fts (uri, title, content) VALUES (?, ?, ?)",
        &.{ uri, title, content },
    ) catch |err| {
        std.debug.print("insert FTS error: {}\n", .{err});
    };
}

pub fn insertPublication(uri: []const u8, did: []const u8, rkey: []const u8, name: []const u8, description: ?[]const u8, base_path: ?[]const u8) !void {
    _ = try execSql(
        "INSERT OR REPLACE INTO publications (uri, did, rkey, name, description, base_path) VALUES (?, ?, ?, ?, ?, ?)",
        &.{ uri, did, rkey, name, description orelse "", base_path orelse "" },
    );
}

pub fn deleteDocument(uri: []const u8) void {
    _ = execSql("DELETE FROM documents WHERE uri = ?", &.{uri}) catch {};
    _ = execSql("DELETE FROM documents_fts WHERE uri = ?", &.{uri}) catch {};
}

pub fn deletePublication(uri: []const u8) void {
    _ = execSql("DELETE FROM publications WHERE uri = ?", &.{uri}) catch {};
}

pub fn searchDocuments(alloc: Allocator, query: []const u8) !std.ArrayList(u8) {
    var output: std.ArrayList(u8) = .{};
    const writer = output.writer(alloc);

    const temp_alloc = gpa.allocator();

    const result = execSql(
        "SELECT f.uri, d.did, d.title, snippet(documents_fts, 2, '<mark>', '</mark>', '...', 32) as snippet, d.created_at, d.rkey, p.base_path FROM documents_fts f JOIN documents d ON f.uri = d.uri LEFT JOIN publications p ON d.publication_uri = p.uri WHERE documents_fts MATCH ? ORDER BY rank LIMIT 50",
        &.{query},
    ) catch {
        try writer.writeAll("[]");
        return output;
    };
    defer temp_alloc.free(result);

    const rows = extractRows(temp_alloc, result) catch {
        try writer.writeAll("[]");
        return output;
    };

    var jw: json.Stringify = .{ .writer = &writer.any() };
    try jw.beginArray();

    for (rows) |row| {
        if (row.len < 7) continue;

        try jw.beginObject();
        try jw.objectField("uri");
        try jw.write(extractText(row[0]));
        try jw.objectField("did");
        try jw.write(extractText(row[1]));
        try jw.objectField("title");
        try jw.write(extractText(row[2]));
        try jw.objectField("snippet");
        try jw.write(extractText(row[3]));
        try jw.objectField("createdAt");
        try jw.write(extractText(row[4]));
        try jw.objectField("rkey");
        try jw.write(extractText(row[5]));
        try jw.objectField("basePath");
        try jw.write(extractText(row[6]));
        try jw.endObject();
    }

    try jw.endArray();
    return output;
}

fn extractRows(alloc: Allocator, result: []const u8) ![]const []const json.Value {
    const parsed = try json.parseFromSlice(json.Value, alloc, result, .{});
    defer parsed.deinit();

    const results = parsed.value.object.get("results") orelse return &.{};
    if (results != .array or results.array.items.len == 0) return &.{};

    const first = results.array.items[0];
    if (first != .object) return &.{};

    const resp = first.object.get("response") orelse return &.{};
    if (resp != .object) return &.{};

    const res = resp.object.get("result") orelse return &.{};
    if (res != .object) return &.{};

    const rows = res.object.get("rows") orelse return &.{};
    if (rows != .array) return &.{};

    var result_rows = std.ArrayList([]const json.Value).init(alloc);
    for (rows.array.items) |row| {
        if (row == .array) {
            try result_rows.append(row.array.items);
        }
    }
    return result_rows.toOwnedSlice();
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

    // libsql:// -> https://
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://{s}/v2/pipeline", .{
        if (mem.startsWith(u8, turso_url, "libsql://"))
            turso_url[9..]
        else
            turso_url,
    }) catch return error.UrlTooLong;

    // build request body
    var body: std.ArrayList(u8) = .{};
    defer body.deinit(alloc);
    const writer = body.writer(alloc);

    var jw: json.Stringify = .{ .writer = &writer.any() };
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

    var auth_buf: [512]u8 = undefined;
    const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{turso_token}) catch return error.AuthTooLong;

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
        .payload = body.items,
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
    const rows = extractRows(alloc, result) catch return 0;
    if (rows.len == 0) return 0;
    if (rows[0].len == 0) return 0;

    const val = rows[0][0];
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
