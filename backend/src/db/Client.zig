//! Turso HTTP API client
//!
//! Turso pipeline API: https://docs.turso.tech/sdk/http/reference

const std = @import("std");
const http = std.http;
const json = std.json;
const mem = std.mem;
const Allocator = mem.Allocator;

const result = @import("result.zig");
pub const Result = result.Result;
pub const Row = result.Row;
pub const BatchResult = result.BatchResult;

const Client = @This();

// Turso request types (mirrors API format)
const TursoArg = struct { type: []const u8 = "text", value: []const u8 };
const TursoStmt = struct { sql: []const u8, args: ?[]const TursoArg = null };
const ExecuteRequest = struct { type: []const u8 = "execute", stmt: TursoStmt };
const CloseRequest = struct { type: []const u8 = "close" };

const URL_BUF_SIZE = 512;
const AUTH_BUF_SIZE = 512;

allocator: Allocator,
url: []const u8,
token: []const u8,
mutex: std.Thread.Mutex = .{},
http_client: http.Client,

pub fn init(allocator: Allocator) !Client {
    const url = std.posix.getenv("TURSO_URL") orelse {
        std.debug.print("TURSO_URL not set\n", .{});
        return error.MissingEnv;
    };
    const token = std.posix.getenv("TURSO_TOKEN") orelse {
        std.debug.print("TURSO_TOKEN not set\n", .{});
        return error.MissingEnv;
    };

    const libsql_prefix = "libsql://";
    const host = if (mem.startsWith(u8, url, libsql_prefix))
        url[libsql_prefix.len..]
    else
        url;

    std.debug.print("turso client initialized: {s}\n", .{host});

    return .{
        .allocator = allocator,
        .url = host,
        .token = token,
        .http_client = .{ .allocator = allocator },
    };
}

pub fn deinit(self: *Client) void {
    self.http_client.deinit();
}

pub fn query(self: *Client, comptime sql: []const u8, args: anytype) !Result {
    comptime validateArgs(sql, @TypeOf(args));
    const args_slice = try self.argsToSlice(args);
    defer self.allocator.free(args_slice);
    const response = try self.executeRaw(sql, args_slice);
    defer self.allocator.free(response);
    return Result.parse(self.allocator, response);
}

pub fn exec(self: *Client, comptime sql: []const u8, args: anytype) !void {
    comptime validateArgs(sql, @TypeOf(args));
    const args_slice = try self.argsToSlice(args);
    defer self.allocator.free(args_slice);
    const response = try self.executeRaw(sql, args_slice);
    self.allocator.free(response);
}

pub const Statement = struct {
    sql: []const u8,
    args: []const []const u8 = &.{},
};

pub fn queryBatch(self: *Client, statements: []const Statement) !BatchResult {
    const response = try self.executeBatchRaw(statements);
    defer self.allocator.free(response);
    return BatchResult.parse(self.allocator, response, statements.len);
}

fn argsToSlice(self: *Client, args: anytype) ![]const []const u8 {
    const ArgsType = @TypeOf(args);
    const info = @typeInfo(ArgsType);

    if (info == .pointer) {
        const child = @typeInfo(info.pointer.child);
        if (child == .@"struct") {
            const fields = child.@"struct".fields;
            const slice = try self.allocator.alloc([]const u8, fields.len);
            inline for (fields, 0..) |field, i| {
                slice[i] = @field(args.*, field.name);
            }
            return slice;
        }
    }

    if (info == .@"struct") {
        const fields = info.@"struct".fields;
        const slice = try self.allocator.alloc([]const u8, fields.len);
        inline for (fields, 0..) |field, i| {
            slice[i] = @field(args, field.name);
        }
        return slice;
    }

    @compileError("args must be a tuple or pointer to tuple");
}

fn executeRaw(self: *Client, sql: []const u8, args: []const []const u8) ![]const u8 {
    self.mutex.lock();
    defer self.mutex.unlock();

    var url_buf: [URL_BUF_SIZE]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://{s}/v2/pipeline", .{self.url}) catch
        return error.UrlTooLong;

    const body = try self.buildRequestBody(sql, args);
    defer self.allocator.free(body);

    var auth_buf: [AUTH_BUF_SIZE]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.token}) catch
        return error.AuthTooLong;

    var response_body: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer response_body.deinit();

    const res = self.http_client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = auth },
        },
        .payload = body,
        .response_writer = &response_body.writer,
    }) catch |err| {
        std.debug.print("turso request failed: {}\n", .{err});
        return error.HttpError;
    };

    if (res.status != .ok) {
        std.debug.print("turso error: {}\n", .{res.status});
        return error.TursoError;
    }

    return try response_body.toOwnedSlice();
}

fn executeBatchRaw(self: *Client, statements: []const Statement) ![]const u8 {
    self.mutex.lock();
    defer self.mutex.unlock();

    var url_buf: [URL_BUF_SIZE]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://{s}/v2/pipeline", .{self.url}) catch
        return error.UrlTooLong;

    const body = try self.buildBatchRequestBody(statements);
    defer self.allocator.free(body);

    var auth_buf: [AUTH_BUF_SIZE]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.token}) catch
        return error.AuthTooLong;

    var response_body: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer response_body.deinit();

    const res = self.http_client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = auth },
        },
        .payload = body,
        .response_writer = &response_body.writer,
    }) catch |err| {
        std.debug.print("turso batch request failed: {}\n", .{err});
        return error.HttpError;
    };

    if (res.status != .ok) {
        std.debug.print("turso batch error: {}\n", .{res.status});
        return error.TursoError;
    }

    return try response_body.toOwnedSlice();
}

fn buildBatchRequestBody(self: *Client, statements: []const Statement) ![]const u8 {
    var body: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer body.deinit();
    var jw: json.Stringify = .{ .writer = &body.writer };

    try jw.beginObject();
    try jw.objectField("requests");
    try jw.beginArray();

    for (statements) |stmt| {
        const turso_args = try self.toTursoArgs(stmt.args);
        defer self.allocator.free(turso_args);
        try jw.write(ExecuteRequest{
            .stmt = .{
                .sql = stmt.sql,
                .args = if (turso_args.len > 0) turso_args else null,
            },
        });
    }

    try jw.write(CloseRequest{});
    try jw.endArray();
    try jw.endObject();

    return try body.toOwnedSlice();
}

fn buildRequestBody(self: *Client, sql: []const u8, args: []const []const u8) ![]const u8 {
    var body: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer body.deinit();
    var jw: json.Stringify = .{ .writer = &body.writer };

    const turso_args = try self.toTursoArgs(args);
    defer self.allocator.free(turso_args);

    try jw.beginObject();
    try jw.objectField("requests");
    try jw.beginArray();
    try jw.write(ExecuteRequest{
        .stmt = .{
            .sql = sql,
            .args = if (turso_args.len > 0) turso_args else null,
        },
    });
    try jw.write(CloseRequest{});
    try jw.endArray();
    try jw.endObject();

    return try body.toOwnedSlice();
}

fn toTursoArgs(self: *Client, args: []const []const u8) ![]const TursoArg {
    if (args.len == 0) return &.{};
    const turso_args = try self.allocator.alloc(TursoArg, args.len);
    for (args, 0..) |arg, i| {
        turso_args[i] = .{ .value = arg };
    }
    return turso_args;
}

fn validateArgs(comptime sql: []const u8, comptime ArgsType: type) void {
    const expected = countPlaceholders(sql);
    const provided = countArgsType(ArgsType);
    if (expected != provided) {
        @compileError(std.fmt.comptimePrint(
            "SQL has {} placeholders but {} args provided",
            .{ expected, provided },
        ));
    }
}

fn countPlaceholders(comptime sql: []const u8) usize {
    var count: usize = 0;
    for (sql) |c| {
        if (c == '?') count += 1;
    }
    return count;
}

fn countArgsType(comptime ArgsType: type) usize {
    const info = @typeInfo(ArgsType);

    if (info == .pointer) {
        const child = @typeInfo(info.pointer.child);
        if (child == .@"struct") {
            return child.@"struct".fields.len;
        }
    }

    if (info == .@"struct") {
        return info.@"struct".fields.len;
    }

    return 0;
}
