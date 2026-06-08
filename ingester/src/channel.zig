//! Tap-compatible `/channel` websocket server.
//!
//! Emits the exact frame shape the backend's tap.zig consumer expects:
//!   {"id":<seq>,"type":"record","record":{"action":..,"did":..,"collection":..,"rkey":..[,"record":<value>]}}
//! and accepts (ignores) the backend's {"type":"ack","id":..} replies — we
//! stream live with no outbox to drain, so acks are advisory.
//!
//! The firehose thread calls broadcast(); the websocket worker thread only
//! reads acks (never writes), so the firehose thread is the sole writer per
//! conn and concurrent-write hazards are avoided.

const std = @import("std");
const Io = std.Io;
const ws = @import("websocket");
const zat = @import("zat");
const logfire = @import("logfire");
const cbor_json = @import("cbor_json.zig");

const MAX_CLIENTS = 8;

pub const Channel = struct {
    // tiny spinlock — std.Thread.Mutex is gone in 0.16 and Io.Mutex needs an
    // io handle the ws worker threads don't carry. Contention is near-zero
    // (one backend client, a few broadcasts/sec), so a spinlock is fine.
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    conns: [MAX_CLIENTS]?*ws.Conn = .{null} ** MAX_CLIENTS,
    acks: u64 = 0,

    fn lock(self: *Channel) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Channel) void {
        self.locked.store(false, .release);
    }

    pub fn register(self: *Channel, conn: *ws.Conn) void {
        self.lock();
        defer self.unlock();
        for (&self.conns) |*slot| {
            if (slot.* == null) {
                slot.* = conn;
                logfire.info("channel: client connected", .{});
                return;
            }
        }
        logfire.warn("channel: client slots full, dropping registration", .{});
    }

    pub fn unregister(self: *Channel, conn: *ws.Conn) void {
        self.lock();
        defer self.unlock();
        for (&self.conns) |*slot| {
            if (slot.* == conn) {
                slot.* = null;
                logfire.info("channel: client disconnected", .{});
                return;
            }
        }
    }

    /// Write a pre-serialized frame to every connected client. Prunes any conn
    /// whose write fails (disconnected). Returns the number of clients written.
    pub fn broadcast(self: *Channel, frame: []const u8) usize {
        self.lock();
        defer self.unlock();
        var n: usize = 0;
        for (&self.conns) |*slot| {
            if (slot.*) |conn| {
                conn.write(frame) catch {
                    slot.* = null;
                    continue;
                };
                n += 1;
            }
        }
        return n;
    }

    pub fn hasClients(self: *Channel) bool {
        self.lock();
        defer self.unlock();
        for (self.conns) |slot| {
            if (slot != null) return true;
        }
        return false;
    }
};

/// Per-connection handler. Registers on connect, deregisters on close.
pub const Handler = struct {
    channel: *Channel,
    conn: *ws.Conn,

    pub fn init(h: *ws.Handshake, conn: *ws.Conn, channel: *Channel) !Handler {
        _ = h;
        channel.register(conn);
        return .{ .channel = channel, .conn = conn };
    }

    pub fn clientMessage(self: *Handler, data: []const u8) !void {
        // backend sends {"type":"ack","id":N}; we have no outbox to drain, so
        // just count them.
        _ = data;
        self.channel.acks += 1;
    }

    pub fn close(self: *Handler) void {
        self.channel.unregister(self.conn);
    }
};

/// Build one `/channel` record frame into `out`. For deletes, `record` is null.
pub fn buildRecordFrame(
    out: *std.Io.Writer.Allocating,
    alloc: std.mem.Allocator,
    id: i64,
    action: []const u8,
    did: []const u8,
    collection: []const u8,
    rkey: []const u8,
    record: ?zat.cbor.Value,
) !void {
    const w = &out.writer;
    try w.print("{{\"id\":{d},\"type\":\"record\",\"record\":{{\"action\":\"{s}\",\"did\":\"{s}\",\"collection\":\"{s}\",\"rkey\":\"{s}\"", .{
        id, action, did, collection, rkey,
    });
    if (record) |value| {
        try w.writeAll(",\"record\":");
        try cbor_json.writeValue(w, alloc, value);
    }
    try w.writeAll("}}");
}

pub const Server = ws.Server(Handler);

/// Run the websocket server (blocks). karlseguin's server manages its own
/// worker pool, so it coexists with the firehose thread fine.
pub fn serve(allocator: std.mem.Allocator, io: Io, channel: *Channel, port: u16) !void {
    var server = try Server.init(allocator, io, .{
        .port = port,
        .address = "0.0.0.0",
        .max_conn = 64,
        .max_message_size = 5 * 1024 * 1024,
    });
    defer server.deinit();
    try server.listen(channel);
}
