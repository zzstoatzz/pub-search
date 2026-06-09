//! Tap-compatible `/channel` websocket server.
//!
//! Emits the exact frame shape the backend's tap.zig consumer expects:
//!   {"id":<seq>,"type":"record","record":{"action":..,"did":..,"collection":..,"rkey":..[,"record":<value>]}}
//! and accepts (ignores) the backend's {"type":"ack","id":..} replies — frames
//! replayed from the ring are delivered at-least-once and the backend's
//! upserts are idempotent, so acks are advisory.
//!
//! While no client is connected (backend deploy/restart), frames land in a
//! bounded in-memory ring instead of being dropped; the ring drains in order
//! to the next client that connects. This stands in for tap's durable outbox —
//! at our matched-event rate (~tens/min) the ring covers hours of backend
//! downtime, and anything beyond that is `/admin/backfill` territory.
//!
//! The firehose thread calls broadcast(); the websocket worker thread only
//! reads acks (never writes outside register's drain, which holds the same
//! lock broadcast does), so concurrent-write hazards are avoided.

const std = @import("std");
const Io = std.Io;
const ws = @import("websocket");
const zat = @import("zat");
const logfire = @import("logfire");
const cbor_json = @import("cbor_json.zig");

const MAX_CLIENTS = 8;
const RING_SLOTS = 8192;
const RING_MAX_BYTES = 64 * 1024 * 1024;

pub const Channel = struct {
    allocator: std.mem.Allocator,
    // tiny spinlock — std.Thread.Mutex is gone in 0.16 and Io.Mutex needs an
    // io handle the ws worker threads don't carry. Contention is near-zero
    // (one backend client, a few broadcasts/sec), so a spinlock is fine.
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    conns: [MAX_CLIENTS]?*ws.Conn = .{null} ** MAX_CLIENTS,
    acks: u64 = 0,
    // FIFO ring of frames buffered while no client is connected.
    ring: [RING_SLOTS]?[]u8 = .{null} ** RING_SLOTS,
    ring_tail: usize = 0, // oldest frame
    ring_len: usize = 0,
    ring_bytes: usize = 0,
    ring_dropped: u64 = 0,

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
                const buffered = self.ring_len;
                self.drainTo(conn);
                logfire.info("channel: client connected, drained {d} buffered frame(s) (dropped while down: {d})", .{ buffered, self.ring_dropped });
                self.ring_dropped = 0;
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

    /// Write a pre-serialized frame to every connected client, or buffer it in
    /// the ring when none is connected. Prunes any conn whose write fails.
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
        if (n == 0) self.buffer(frame);
        return n;
    }

    /// Copy a frame into the ring, evicting oldest frames to stay within the
    /// slot and byte budgets. Caller holds the lock.
    fn buffer(self: *Channel, frame: []const u8) void {
        while (self.ring_len > 0 and (self.ring_len == RING_SLOTS or self.ring_bytes + frame.len > RING_MAX_BYTES)) {
            self.evictOldest();
            self.ring_dropped += 1;
        }
        const copy = self.allocator.dupe(u8, frame) catch {
            self.ring_dropped += 1;
            return;
        };
        const head = (self.ring_tail + self.ring_len) % RING_SLOTS;
        self.ring[head] = copy;
        self.ring_len += 1;
        self.ring_bytes += copy.len;
    }

    /// Replay buffered frames in FIFO order. On write failure the conn is dead:
    /// prune it and keep the remaining frames for the next client. Caller holds
    /// the lock.
    fn drainTo(self: *Channel, conn: *ws.Conn) void {
        while (self.ring_len > 0) {
            const frame = self.ring[self.ring_tail].?;
            conn.write(frame) catch {
                for (&self.conns) |*slot| {
                    if (slot.* == conn) slot.* = null;
                }
                return;
            };
            self.ring[self.ring_tail] = null;
            self.ring_tail = (self.ring_tail + 1) % RING_SLOTS;
            self.ring_len -= 1;
            self.ring_bytes -= frame.len;
            self.allocator.free(frame);
        }
    }

    fn evictOldest(self: *Channel) void {
        const frame = self.ring[self.ring_tail].?;
        self.ring_bytes -= frame.len;
        self.allocator.free(frame);
        self.ring[self.ring_tail] = null;
        self.ring_tail = (self.ring_tail + 1) % RING_SLOTS;
        self.ring_len -= 1;
    }
};

/// Per-connection handler. Registers on connect, deregisters on close.
pub const Handler = struct {
    channel: *Channel,
    conn: *ws.Conn,

    pub fn init(h: *ws.Handshake, conn: *ws.Conn, channel: *Channel) !Handler {
        _ = h;
        return .{ .channel = channel, .conn = conn };
    }

    // register (and drain the ring) only AFTER the server has written the
    // HTTP 101 handshake reply — registering in init() puts replayed frames
    // on the wire ahead of the upgrade response, corrupting the handshake.
    pub fn afterInit(self: *Handler) !void {
        self.channel.register(self.conn);
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
        // fly 6PN (.internal) is IPv6-only — "::" binds both families.
        .address = "::",
        .max_conn = 64,
        .max_message_size = 5 * 1024 * 1024,
    });
    defer server.deinit();
    try server.listen(channel);
}
