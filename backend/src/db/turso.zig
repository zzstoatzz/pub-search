const std = @import("std");
const http = std.http;
const json = std.json;
const mem = std.mem;
const Allocator = mem.Allocator;

const result = @import("result.zig");
pub const Result = result.Result;
pub const Row = result.Row;

const URL_BUF_SIZE = 512;
const AUTH_BUF_SIZE = 512;

/// Count `?` placeholders in SQL at comptime
fn countPlaceholders(comptime sql: []const u8) usize {
    var count: usize = 0;
    for (sql) |c| {
        if (c == '?') count += 1;
    }
    return count;
}

/// Count args in a tuple type (handles both direct tuples and pointers to tuples)
fn countArgsType(comptime ArgsType: type) usize {
    const args_type_info = @typeInfo(ArgsType);

    if (args_type_info == .pointer) {
        const child_info = @typeInfo(args_type_info.pointer.child);
        if (child_info == .@"struct") {
            return child_info.@"struct".fields.len;
        }
    }

    if (args_type_info == .@"struct") {
        return args_type_info.@"struct".fields.len;
    }

    return 0;
}

pub const Client = struct {
    allocator: Allocator,
    url: []const u8,
    token: []const u8,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: Allocator) !Client {
        const url = std.posix.getenv("TURSO_URL") orelse {
            std.debug.print("TURSO_URL not set\n", .{});
            return error.MissingEnv;
        };
        const token = std.posix.getenv("TURSO_TOKEN") orelse {
            std.debug.print("TURSO_TOKEN not set\n", .{});
            return error.MissingEnv;
        };

        // strip libsql:// prefix if present
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
        };
    }

    /// Execute a query and return parsed results.
    /// Validates parameter count at compile time.
    pub fn query(self: *Client, comptime sql: []const u8, args: anytype) !Result {
        const expected = comptime countPlaceholders(sql);
        const provided = comptime countArgsType(@TypeOf(args));
        if (expected != provided) {
            @compileError(std.fmt.comptimePrint(
                "SQL has {} placeholders but {} args provided",
                .{ expected, provided },
            ));
        }
        const args_slice = try self.argsToSlice(args);
        defer self.allocator.free(args_slice);
        const response = try self.executeRaw(sql, args_slice);
        defer self.allocator.free(response);
        return Result.parse(self.allocator, response);
    }

    /// Execute a statement, ignoring results.
    /// Validates parameter count at compile time.
    pub fn exec(self: *Client, comptime sql: []const u8, args: anytype) !void {
        const expected = comptime countPlaceholders(sql);
        const provided = comptime countArgsType(@TypeOf(args));
        if (expected != provided) {
            @compileError(std.fmt.comptimePrint(
                "SQL has {} placeholders but {} args provided",
                .{ expected, provided },
            ));
        }
        const args_slice = try self.argsToSlice(args);
        defer self.allocator.free(args_slice);
        const response = try self.executeRaw(sql, args_slice);
        self.allocator.free(response);
    }

    /// Convert tuple/struct args to slice, with comptime validation
    fn argsToSlice(self: *Client, args: anytype) ![]const []const u8 {
        const ArgsType = @TypeOf(args);
        const args_type_info = @typeInfo(ArgsType);

        // handle pointer to tuple (e.g., &.{a, b, c})
        if (args_type_info == .pointer) {
            const child_info = @typeInfo(args_type_info.pointer.child);
            if (child_info == .@"struct") {
                const fields = child_info.@"struct".fields;
                const slice = try self.allocator.alloc([]const u8, fields.len);
                inline for (fields, 0..) |field, i| {
                    slice[i] = @field(args.*, field.name);
                }
                return slice;
            }
        }

        // handle direct struct/tuple
        if (args_type_info == .@"struct") {
            const fields = args_type_info.@"struct".fields;
            const slice = try self.allocator.alloc([]const u8, fields.len);
            inline for (fields, 0..) |field, i| {
                slice[i] = @field(args, field.name);
            }
            return slice;
        }

        @compileError("args must be a tuple or pointer to tuple");
    }

    /// Execute and return raw JSON response (caller owns memory)
    fn executeRaw(self: *Client, sql: []const u8, args: []const []const u8) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var url_buf: [URL_BUF_SIZE]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://{s}/v2/pipeline", .{self.url}) catch
            return error.UrlTooLong;

        // build request body
        const body = try self.buildRequestBody(sql, args);
        defer self.allocator.free(body);

        var auth_buf: [AUTH_BUF_SIZE]u8 = undefined;
        const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.token}) catch
            return error.AuthTooLong;

        var client: http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        var response_body: std.Io.Writer.Allocating = .init(self.allocator);
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
            std.debug.print("turso request failed: {}\n", .{err});
            return error.HttpError;
        };

        if (res.status != .ok) {
            std.debug.print("turso error: {}\n", .{res.status});
            return error.TursoError;
        }

        return try response_body.toOwnedSlice();
    }

    fn buildRequestBody(self: *Client, sql: []const u8, args: []const []const u8) ![]const u8 {
        var body: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer body.deinit();

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

        try jw.endObject(); // stmt
        try jw.endObject(); // execute request

        // close statement
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("close");
        try jw.endObject();

        try jw.endArray(); // requests
        try jw.endObject(); // root

        return try body.toOwnedSlice();
    }
};
