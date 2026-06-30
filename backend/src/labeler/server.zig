//! XRPC server for AT Protocol labeler
//!
//! serves two endpoints:
//!   - com.atproto.label.subscribeLabels (WebSocket, CBOR-framed event stream)
//!   - com.atproto.label.queryLabels (HTTP GET, JSON response)

const std = @import("std");
const websocket = @import("websocket");
const zat = @import("zat");
const cbor = zat.cbor;
const label_mod = @import("label.zig");
const store_mod = @import("store.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.server);

// module state — initialized via init(), not from a global
var io: Io = undefined;

pub fn init(app_io: Io) void {
    io = app_io;
}

pub const Server = struct {
    allocator: Allocator,
    store: *store_mod.Store,
    subscribers: std.ArrayList(*Subscriber),
    mutex: Io.Mutex = .init,

    pub fn init(allocator: Allocator, store: *store_mod.Store) Server {
        return .{
            .allocator = allocator,
            .store = store,
            .subscribers = .empty,
        };
    }

    pub fn deinit(self: *Server) void {
        self.subscribers.deinit(self.allocator);
    }

    /// broadcast a new label to all connected subscribers.
    /// called after a label is stored.
    pub fn broadcast(self: *Server, seq: i64, encoded_label: []const u8) void {
        const frame = self.buildLabelsFrame(seq, encoded_label) catch |err| {
            log.err("failed to build frame: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(frame);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var i: usize = 0;
        while (i < self.subscribers.items.len) {
            const sub = self.subscribers.items[i];
            sub.conn.writeBin(frame) catch {
                // subscriber disconnected, remove
                log.info("subscriber disconnected, removing", .{});
                _ = self.subscribers.swapRemove(i);
                continue;
            };
            i += 1;
        }
    }

    fn buildLabelsFrame(self: *Server, seq: i64, encoded_label: []const u8) ![]u8 {
        // payload: {seq: <int>, labels: [<encoded label as bytes>]}
        // we re-decode the stored CBOR to embed it as a CBOR value in the frame.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const label_value = try cbor.decodeAll(alloc, encoded_label);

        const labels_array = try alloc.alloc(cbor.Value, 1);
        labels_array[0] = label_value;

        const entries = try alloc.alloc(cbor.Value.MapEntry, 2);
        entries[0] = .{ .key = "labels", .value = .{ .array = labels_array } };
        entries[1] = .{ .key = "seq", .value = .{ .unsigned = @intCast(seq) } };

        const payload: cbor.Value = .{ .map = entries };

        return label_mod.encodeEventFrame(self.allocator, 1, "#labels", payload);
    }

    /// add a subscriber connection.
    pub fn addSubscriber(self: *Server, conn: *websocket.Conn, cursor: ?i64) void {
        const sub = self.allocator.create(Subscriber) catch return;
        sub.* = .{ .conn = conn };

        // backfill from cursor
        if (cursor) |cur| {
            self.backfill(conn, cur) catch |err| {
                log.err("backfill failed: {s}", .{@errorName(err)});
            };
        }

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.subscribers.append(self.allocator, sub) catch {
            self.allocator.destroy(sub);
        };
    }

    /// remove a subscriber connection.
    pub fn removeSubscriber(self: *Server, conn: *websocket.Conn) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        for (self.subscribers.items, 0..) |sub, i| {
            if (sub.conn == conn) {
                self.allocator.destroy(sub);
                _ = self.subscribers.swapRemove(i);
                return;
            }
        }
    }

    fn backfill(self: *Server, conn: *websocket.Conn, cursor: i64) !void {
        const latest = self.store.latestSeq();

        // check if cursor is in the future
        if (cursor > latest) {
            const frame = try label_mod.encodeEventFrame(self.allocator, -1, null, .{ .map = &.{
                .{ .key = "error", .value = .{ .text = "FutureCursor" } },
                .{ .key = "message", .value = .{ .text = "cursor is in the future" } },
            } });
            defer self.allocator.free(frame);
            conn.writeBin(frame) catch return;
            return;
        }

        // send outdated cursor info if needed (cursor=0 means "from beginning", not outdated)
        if (cursor > 0) {
            const info_frame = try label_mod.encodeEventFrame(self.allocator, 1, "#info", .{ .map = &.{
                .{ .key = "message", .value = .{ .text = "OutdatedCursor" } },
                .{ .key = "name", .value = .{ .text = "OutdatedCursor" } },
            } });
            defer self.allocator.free(info_frame);
            conn.writeBin(info_frame) catch return;
        }

        // send stored labels in batches
        var cur = cursor;
        while (true) {
            const labels = self.store.queryByCursor(self.allocator, cur, 100) catch return;
            defer {
                for (labels) |item| {
                    self.allocator.free(item.label.src);
                    self.allocator.free(item.label.uri);
                    self.allocator.free(item.label.val);
                    self.allocator.free(item.label.cts);
                    self.allocator.free(item.encoded);
                    if (item.label.sig) |s| self.allocator.free(s);
                    if (item.label.cid) |ci| self.allocator.free(ci);
                    if (item.label.exp) |e| self.allocator.free(e);
                }
                self.allocator.free(labels);
            }

            if (labels.len == 0) break;

            for (labels) |stored| {
                const frame = self.buildLabelsFrame(stored.seq, stored.encoded) catch continue;
                defer self.allocator.free(frame);
                conn.writeBin(frame) catch return;
            }

            cur = labels[labels.len - 1].seq;
        }
    }

    /// handle an HTTP request (non-WebSocket).
    pub fn handleHttp(
        self: *Server,
        conn: *websocket.Conn,
        method: []const u8,
        url: []const u8,
    ) void {
        // split path and query
        const qmark = std.mem.indexOfScalar(u8, url, '?');
        const path = url[0..(qmark orelse url.len)];
        const query = if (qmark) |q| url[q + 1 ..] else "";

        if (std.mem.eql(u8, method, "GET") and
            std.mem.eql(u8, path, "/xrpc/com.atproto.label.queryLabels"))
        {
            self.handleQueryLabels(conn, query);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/health")) {
            httpRespond(conn, "200 OK", "application/json", "{\"status\":\"ok\"}");
        } else {
            httpRespond(conn, "404 Not Found", "application/json",
                \\{"error":"NotFound","message":"endpoint not found"}
            );
        }
    }

    fn handleQueryLabels(self: *Server, conn: *websocket.Conn, query: []const u8) void {
        // parse uriPatterns param
        const uri = queryParam(query, "uriPatterns") orelse {
            httpRespond(conn, "400 Bad Request", "application/json",
                \\{"error":"InvalidRequest","message":"uriPatterns parameter required"}
            );
            return;
        };

        const labels = self.store.queryBySubject(self.allocator, uri) catch {
            httpRespond(conn, "500 Internal Server Error", "application/json",
                \\{"error":"InternalError","message":"database query failed"}
            );
            return;
        };
        defer {
            for (labels) |item| {
                self.allocator.free(item.label.src);
                self.allocator.free(item.label.uri);
                self.allocator.free(item.label.val);
                self.allocator.free(item.label.cts);
                self.allocator.free(item.encoded);
                if (item.label.sig) |s| self.allocator.free(s);
                if (item.label.cid) |ci| self.allocator.free(ci);
                if (item.label.exp) |e| self.allocator.free(e);
            }
            self.allocator.free(labels);
        }

        // build JSON response
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;

        w.writeAll("{\"labels\":[") catch return;

        for (labels, 0..) |stored, i| {
            if (i > 0) w.writeByte(',') catch return;
            writeJsonLabel(w, &stored) catch return;
        }

        w.writeAll("]}") catch return;

        httpRespond(conn, "200 OK", "application/json", w.buffered());
    }
};

const Subscriber = struct {
    conn: *websocket.Conn,
};

/// websocket handler for subscribeLabels
pub fn Handler(comptime ServerT: type) type {
    return struct {
        server: *ServerT,
        conn: *websocket.Conn,
        cursor: ?i64 = null,

        const Self = @This();

        pub fn init(handshake: *const websocket.Handshake, conn: *websocket.Conn, ctx: *ServerT) !Self {
            _ = handshake;
            return .{
                .server = ctx,
                .conn = conn,
            };
        }

        pub fn afterInit(self: *Self, _: *ServerT) !void {
            self.server.addSubscriber(self.conn, self.cursor);
        }

        pub fn clientMessage(_: *Self, _: []const u8) !void {
            // labeler is write-only to subscribers
        }

        pub fn close(self: *Self) void {
            self.server.removeSubscriber(self.conn);
        }

        pub fn httpFallback(conn: *websocket.Conn, method: []const u8, url: []const u8, _: []const u8, _: *const websocket.Handshake.KeyValue, ctx_ptr: ?*anyopaque) void {
            const ctx: *ServerT = @ptrCast(@alignCast(ctx_ptr.?));
            ctx.handleHttp(conn, method, url);
        }
    };
}

// === HTTP helpers ===

fn httpRespond(conn: *websocket.Conn, status: []const u8, content_type: []const u8, body: []const u8) void {
    var buf: [512]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\n\r\n", .{
        status, content_type, body.len,
    }) catch return;
    conn.writeFramed(header) catch return;
    if (body.len > 0) conn.writeFramed(body) catch return;
}

fn queryParam(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) {
            return pair[eq + 1 ..];
        }
    }
    return null;
}

fn writeJsonLabel(w: anytype, stored: *const store_mod.StoredLabel) !void {
    const lbl = &stored.label;
    try w.writeAll("{");
    try w.print("\"ver\":{d}", .{lbl.ver});
    try w.writeAll(",\"src\":\"");
    try w.writeAll(lbl.src);
    try w.writeAll("\",\"uri\":\"");
    try w.writeAll(lbl.uri);
    try w.writeByte('"');

    if (lbl.cid) |cid| {
        try w.writeAll(",\"cid\":\"");
        try w.writeAll(cid);
        try w.writeByte('"');
    }

    try w.writeAll(",\"val\":\"");
    try w.writeAll(lbl.val);
    try w.writeAll("\",\"cts\":\"");
    try w.writeAll(lbl.cts);
    try w.writeByte('"');

    if (lbl.neg) try w.writeAll(",\"neg\":true");
    if (lbl.exp) |exp| {
        try w.writeAll(",\"exp\":\"");
        try w.writeAll(exp);
        try w.writeByte('"');
    }

    // sig as base64
    if (lbl.sig) |sig| {
        try w.writeAll(",\"sig\":\"");
        const encoder = std.base64.standard.Encoder;
        var b64_buf: [88]u8 = undefined; // 64 bytes → 88 chars
        const b64_len = encoder.calcSize(sig.len);
        const b64 = encoder.encode(b64_buf[0..b64_len], sig);
        try w.writeAll(b64);
        try w.writeByte('"');
    }

    try w.writeByte('}');
}

// === tests ===

test "query param parsing" {
    try std.testing.expectEqualStrings("hello", queryParam("foo=hello&bar=world", "foo").?);
    try std.testing.expectEqualStrings("world", queryParam("foo=hello&bar=world", "bar").?);
    try std.testing.expect(queryParam("foo=hello", "bar") == null);
    try std.testing.expect(queryParam("", "foo") == null);
}

test "event frame structure" {
    const allocator = std.testing.allocator;

    const payload: cbor.Value = .{ .map = &.{
        .{ .key = "seq", .value = .{ .unsigned = 1 } },
        .{ .key = "labels", .value = .{ .array = &.{} } },
    } };

    const frame = try label_mod.encodeEventFrame(allocator, 1, "#labels", payload);
    defer allocator.free(frame);

    // verify we can decode header + payload from the frame
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const header = try cbor.decode(alloc, frame);
    try std.testing.expectEqual(@as(u64, 1), header.value.getUint("op").?);
    try std.testing.expectEqualStrings("#labels", header.value.getString("t").?);

    const body = try cbor.decodeAll(alloc, frame[header.consumed..]);
    try std.testing.expectEqual(@as(u64, 1), body.getUint("seq").?);
}
