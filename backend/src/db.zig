const std = @import("std");
const mem = std.mem;
const Thread = std.Thread;
const Allocator = mem.Allocator;
const json = std.json;
const http = std.http;
const Io = std.Io;

pub var turso_url: []const u8 = undefined;
pub var turso_token: []const u8 = undefined;
pub var mutex: Thread.Mutex = .{};

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};

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
    _ = try execSqlNoArgs(
        \\CREATE TABLE IF NOT EXISTS documents (
        \\  uri TEXT PRIMARY KEY,
        \\  did TEXT NOT NULL,
        \\  rkey TEXT NOT NULL,
        \\  title TEXT NOT NULL,
        \\  content TEXT NOT NULL,
        \\  created_at TEXT
        \\)
    );

    _ = try execSqlNoArgs(
        \\CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(
        \\  uri UNINDEXED,
        \\  title,
        \\  content
        \\)
    );

    _ = try execSqlNoArgs(
        \\CREATE TABLE IF NOT EXISTS publications (
        \\  uri TEXT PRIMARY KEY,
        \\  did TEXT NOT NULL,
        \\  rkey TEXT NOT NULL,
        \\  name TEXT NOT NULL,
        \\  description TEXT
        \\)
    );

    std.debug.print("turso schema initialized with FTS5\n", .{});
}

pub fn insertDocument(uri: []const u8, did: []const u8, rkey: []const u8, title: []const u8, content: []const u8, created_at: ?[]const u8) !void {
    _ = try execSqlWithArgs(
        "INSERT OR REPLACE INTO documents (uri, did, rkey, title, content, created_at) VALUES (?, ?, ?, ?, ?, ?)",
        &[_][]const u8{ uri, did, rkey, title, content, created_at orelse "" },
    );

    // delete from fts first (ignore errors)
    _ = execSqlWithArgs("DELETE FROM documents_fts WHERE uri = ?", &[_][]const u8{uri}) catch {};

    _ = execSqlWithArgs(
        "INSERT INTO documents_fts (uri, title, content) VALUES (?, ?, ?)",
        &[_][]const u8{ uri, title, content },
    ) catch |err| {
        std.debug.print("insert FTS error: {}\n", .{err});
    };
}

pub fn insertPublication(uri: []const u8, did: []const u8, rkey: []const u8, name: []const u8, description: ?[]const u8) !void {
    _ = try execSqlWithArgs(
        "INSERT OR REPLACE INTO publications (uri, did, rkey, name, description) VALUES (?, ?, ?, ?, ?)",
        &[_][]const u8{ uri, did, rkey, name, description orelse "" },
    );
}

pub fn deleteDocument(uri: []const u8) void {
    _ = execSqlWithArgs("DELETE FROM documents WHERE uri = ?", &[_][]const u8{uri}) catch {};
    _ = execSqlWithArgs("DELETE FROM documents_fts WHERE uri = ?", &[_][]const u8{uri}) catch {};
}

pub fn deletePublication(uri: []const u8) void {
    _ = execSqlWithArgs("DELETE FROM publications WHERE uri = ?", &[_][]const u8{uri}) catch {};
}

pub fn searchDocuments(alloc: Allocator, query: []const u8) !std.ArrayList(u8) {
    var response: std.ArrayList(u8) = .{};
    try response.appendSlice(alloc, "[");

    const temp_alloc = gpa.allocator();

    const result = execSqlWithArgs(
        "SELECT f.uri, d.did, d.title, snippet(documents_fts, 2, '<mark>', '</mark>', '...', 32) as snippet, d.created_at FROM documents_fts f JOIN documents d ON f.uri = d.uri WHERE documents_fts MATCH ? ORDER BY rank LIMIT 50",
        &[_][]const u8{query},
    ) catch {
        try response.appendSlice(alloc, "]");
        return response;
    };
    defer temp_alloc.free(result);

    const parsed = json.parseFromSlice(json.Value, temp_alloc, result, .{}) catch {
        try response.appendSlice(alloc, "]");
        return response;
    };
    defer parsed.deinit();

    const results = parsed.value.object.get("results") orelse {
        try response.appendSlice(alloc, "]");
        return response;
    };

    if (results != .array or results.array.items.len == 0) {
        try response.appendSlice(alloc, "]");
        return response;
    }

    const first_result = results.array.items[0];
    if (first_result != .object) {
        try response.appendSlice(alloc, "]");
        return response;
    }

    const resp_obj = first_result.object.get("response") orelse {
        try response.appendSlice(alloc, "]");
        return response;
    };

    if (resp_obj != .object) {
        try response.appendSlice(alloc, "]");
        return response;
    }

    const result_obj = resp_obj.object.get("result") orelse {
        try response.appendSlice(alloc, "]");
        return response;
    };

    if (result_obj != .object) {
        try response.appendSlice(alloc, "]");
        return response;
    }

    const rows = result_obj.object.get("rows") orelse {
        try response.appendSlice(alloc, "]");
        return response;
    };

    if (rows != .array) {
        try response.appendSlice(alloc, "]");
        return response;
    }

    var first = true;
    for (rows.array.items) |row| {
        if (row != .array) continue;
        const cols = row.array.items;
        if (cols.len < 5) continue;

        if (!first) try response.appendSlice(alloc, ",");
        first = false;

        const uri = getTextValue(cols[0]);
        const did = getTextValue(cols[1]);
        const title = getTextValue(cols[2]);
        const snippet = getTextValue(cols[3]);
        const created_at = getTextValue(cols[4]);

        try response.appendSlice(alloc, "{\"uri\":\"");
        try appendEscaped(alloc, &response, uri);
        try response.appendSlice(alloc, "\",\"did\":\"");
        try appendEscaped(alloc, &response, did);
        try response.appendSlice(alloc, "\",\"title\":\"");
        try appendEscaped(alloc, &response, title);
        try response.appendSlice(alloc, "\",\"snippet\":\"");
        try appendEscaped(alloc, &response, snippet);
        try response.appendSlice(alloc, "\",\"createdAt\":\"");
        try appendEscaped(alloc, &response, created_at);
        try response.appendSlice(alloc, "\"}");
    }

    try response.appendSlice(alloc, "]");
    return response;
}

fn getTextValue(val: json.Value) []const u8 {
    return switch (val) {
        .string => |s| s,
        .object => |obj| if (obj.get("value")) |v| (if (v == .string) v.string else "") else "",
        else => "",
    };
}

fn appendEscaped(alloc: Allocator, list: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(alloc, "\\\""),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\r' => try list.appendSlice(alloc, "\\r"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            else => try list.append(alloc, c),
        }
    }
}

fn execSqlNoArgs(sql: []const u8) ![]const u8 {
    return execSqlWithArgs(sql, &[_][]const u8{});
}

fn execSqlWithArgs(sql: []const u8, args: []const []const u8) ![]const u8 {
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

    // build request body with parameterized args
    var body: std.ArrayList(u8) = .{};
    defer body.deinit(alloc);

    try body.appendSlice(alloc, "{\"requests\":[{\"type\":\"execute\",\"stmt\":{\"sql\":\"");
    for (sql) |c| {
        switch (c) {
            '"' => try body.appendSlice(alloc, "\\\""),
            '\\' => try body.appendSlice(alloc, "\\\\"),
            '\n' => try body.appendSlice(alloc, "\\n"),
            '\r' => try body.appendSlice(alloc, "\\r"),
            '\t' => try body.appendSlice(alloc, "\\t"),
            else => try body.append(alloc, c),
        }
    }
    try body.appendSlice(alloc, "\"");

    // add args array if we have any
    if (args.len > 0) {
        try body.appendSlice(alloc, ",\"args\":[");
        for (args, 0..) |arg, i| {
            if (i > 0) try body.appendSlice(alloc, ",");
            try body.appendSlice(alloc, "{\"type\":\"text\",\"value\":\"");
            for (arg) |c| {
                switch (c) {
                    '"' => try body.appendSlice(alloc, "\\\""),
                    '\\' => try body.appendSlice(alloc, "\\\\"),
                    '\n' => try body.appendSlice(alloc, "\\n"),
                    '\r' => try body.appendSlice(alloc, "\\r"),
                    '\t' => try body.appendSlice(alloc, "\\t"),
                    else => try body.append(alloc, c),
                }
            }
            try body.appendSlice(alloc, "\"}");
        }
        try body.appendSlice(alloc, "]");
    }

    try body.appendSlice(alloc, "}},{\"type\":\"close\"}]}");

    var auth_buf: [512]u8 = undefined;
    const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{turso_token}) catch return error.AuthTooLong;

    var client: http.Client = .{ .allocator = alloc };
    defer client.deinit();

    var aw: Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = auth_header },
        },
        .payload = body.items,
        .response_writer = &aw.writer,
    }) catch |err| {
        std.debug.print("turso request failed: {}\n", .{err});
        return error.HttpError;
    };

    if (result.status != .ok) {
        std.debug.print("turso error: {}\n", .{result.status});
        return error.TursoError;
    }

    return try aw.toOwnedSlice();
}

pub fn getStats() struct { documents: i64, publications: i64 } {
    const doc_result = execSqlNoArgs("SELECT COUNT(*) FROM documents") catch return .{ .documents = 0, .publications = 0 };
    defer gpa.allocator().free(doc_result);

    const pub_result = execSqlNoArgs("SELECT COUNT(*) FROM publications") catch return .{ .documents = 0, .publications = 0 };
    defer gpa.allocator().free(pub_result);

    const doc_count = parseCount(doc_result);
    const pub_count = parseCount(pub_result);

    return .{ .documents = doc_count, .publications = pub_count };
}

fn parseCount(result: []const u8) i64 {
    const alloc = gpa.allocator();
    const parsed = json.parseFromSlice(json.Value, alloc, result, .{}) catch return 0;
    defer parsed.deinit();

    const results = parsed.value.object.get("results") orelse return 0;
    if (results != .array or results.array.items.len == 0) return 0;

    const first = results.array.items[0];
    if (first != .object) return 0;

    const resp = first.object.get("response") orelse return 0;
    if (resp != .object) return 0;

    const res = resp.object.get("result") orelse return 0;
    if (res != .object) return 0;

    const rows = res.object.get("rows") orelse return 0;
    if (rows != .array or rows.array.items.len == 0) return 0;

    const row = rows.array.items[0];
    if (row != .array or row.array.items.len == 0) return 0;

    const val = row.array.items[0];
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
