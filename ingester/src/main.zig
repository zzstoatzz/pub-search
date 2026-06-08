//! leaflet-search firehose ingester.
//!
//! Standalone service that replaces the indigo `tap` sidecar. It consumes the
//! real firehose (com.atproto.sync.subscribeRepos), filters to leaflet-search's
//! collections, and (eventually) verifies each commit (MST + signature) in
//! process before re-emitting verified records over a tap-compatible `/channel`
//! websocket so the backend's existing consumer can point at us unchanged.
//!
//! Current mode: COMPARISON / observe-only. Connects + filters + persists its
//! firehose cursor + emits one `ingester.captured` log per matched record so we
//! can diff its coverage against what tap actually delivered to Turso, BEFORE
//! cutting the backend over. Verification and the /channel server are the
//! remaining cutover-blockers (see project_own_firehose_ingester memory).

const std = @import("std");
const Io = std.Io;
const logfire = @import("logfire");
const zat = @import("zat");
const ch = @import("channel.zig");

// Collections we index — mirrors the backend's TAP_COLLECTION_FILTERS / tap.zig.
const COLLECTIONS = [_][]const u8{
    "pub.leaflet.document",
    "pub.leaflet.publication",
    "pub.leaflet.interactions.recommend",
    "site.standard.document",
    "site.standard.publication",
    "site.standard.graph.recommend",
    "com.whtwnd.blog.entry",
};

fn isTracked(collection: []const u8) bool {
    for (COLLECTIONS) |c| {
        if (std.mem.eql(u8, c, collection)) return true;
    }
    return false;
}

// Persist the firehose cursor every this many events so we resume across our
// OWN restarts (zat only keeps last_seq in memory). ~every few seconds at
// firehose volume; cheap atomic file write.
const CURSOR_PERSIST_EVERY: u64 = 500;

// std.fs was removed in zig 0.16; use POSIX std.c (matches backend timing.zig).
fn cursorPath() [:0]const u8 {
    return if (std.c.getenv("CURSOR_PATH")) |p| std.mem.span(p) else "/data/cursor";
}

fn readCursor(path: [:0]const u8) ?i64 {
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var buf: [32]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    if (n <= 0) return null;
    const trimmed = std.mem.trim(u8, buf[0..@intCast(n)], &std.ascii.whitespace);
    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

fn persistCursor(path: [:0]const u8, seq: i64) void {
    var tmp_buf: [256]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}.tmp", .{path}) catch return;
    const fd = std.c.open(tmp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return;
    var num_buf: [32]u8 = undefined;
    const body = std.fmt.bufPrint(&num_buf, "{d}", .{seq}) catch {
        _ = std.c.close(fd);
        return;
    };
    var total: usize = 0;
    while (total < body.len) {
        const w = std.c.write(fd, body[total..].ptr, body.len - total);
        if (w <= 0) break;
        total += @intCast(w);
    }
    _ = std.c.close(fd);
    _ = std.c.rename(tmp.ptr, path.ptr);
}

const Handler = struct {
    allocator: std.mem.Allocator,
    channel: *ch.Channel,
    matched: u64 = 0,
    events: u64 = 0,
    last_seq: i64 = 0,
    cursor_path: [:0]const u8,

    pub fn onEvent(self: *Handler, event: zat.FirehoseEvent) void {
        if (event.seq()) |s| self.last_seq = s;
        self.events += 1;

        switch (event) {
            .commit => |commit| {
                for (commit.ops) |op| {
                    if (!isTracked(op.collection)) continue;
                    self.matched += 1;

                    // comparison signal (uri = at://{did}/{collection}/{rkey}).
                    logfire.info("ingester.captured action={s} collection={s} did={s} rkey={s} seq={d}", .{
                        @tagName(op.action), op.collection, commit.repo, op.rkey, commit.seq,
                    });

                    // emit the tap-compatible /channel frame to any connected
                    // backend. NOTE: unverified for now (verification blocked on
                    // zat exposing raw CAR bytes) — safe because nothing points
                    // at us yet; we won't cut over until verification lands.
                    self.emit(op, commit.repo, commit.seq);
                }
            },
            else => {},
        }

        if (self.events % CURSOR_PERSIST_EVERY == 0) {
            persistCursor(self.cursor_path, self.last_seq);
            logfire.debug("ingester progress: events={d} matched={d} seq={d}", .{ self.events, self.matched, self.last_seq });
        }
    }

    fn emit(self: *Handler, op: zat.firehose.RepoOp, did: []const u8, seq: i64) void {
        if (!self.channel.hasClients()) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var out: std.Io.Writer.Allocating = .init(a);
        ch.buildRecordFrame(&out, a, seq, @tagName(op.action), did, op.collection, op.rkey, op.record) catch |err| {
            logfire.warn("channel: frame build failed: {s}", .{@errorName(err)});
            return;
        };
        _ = self.channel.broadcast(out.written());
    }

    pub fn onError(_: *Handler, err: anyerror) void {
        logfire.warn("firehose error: {s}, reconnecting...", .{@errorName(err)});
    }
};

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var threaded = Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    _ = logfire.configure(.{
        .service_name = "leaflet-ingester",
        .service_version = "0.0.1",
        .environment = if (std.c.getenv("FLY_APP_NAME")) |p| std.mem.span(p) else "development",
    }) catch |err| {
        std.debug.print("logfire init failed: {}, continuing without observability\n", .{err});
    };

    // Relay failover list. zat rotates through these on reconnect (exponential
    // backoff, reset on host switch) and resumes from ?cursor=last_seq, so a
    // downed relay fails over and a blip replays. Override with RELAY_HOSTS.
    var hosts_buf: [8][]const u8 = undefined;
    const hosts: []const []const u8 = if (std.c.getenv("RELAY_HOSTS")) |p| blk: {
        var n: usize = 0;
        var it = std.mem.tokenizeScalar(u8, std.mem.span(p), ',');
        while (it.next()) |h| {
            if (n >= hosts_buf.len) break;
            hosts_buf[n] = h;
            n += 1;
        }
        break :blk hosts_buf[0..n];
    } else &.{
        "relay1.us-east.bsky.network",
        "relay1.us-west.bsky.network",
        "zlay.waow.tech",
        "bsky.network",
    };

    const path = cursorPath();
    const cursor = readCursor(path);

    // start the tap-compatible /channel websocket server (the backend points
    // its TAP_HOST here to cut over — once verification lands).
    const port: u16 = blk: {
        const s = if (std.c.getenv("PORT")) |p| std.mem.span(p) else "2480";
        break :blk std.fmt.parseInt(u16, s, 10) catch 2480;
    };
    var channel = ch.Channel{};
    const server_thread = ch.start(allocator, io, &channel, port) catch |err| {
        logfire.err("channel: failed to start server on port {d}: {}", .{ port, err });
        return err;
    };
    server_thread.detach();
    logfire.info("leaflet-ingester starting, /channel on :{d}, {d} relay host(s), primary={s}, resume_cursor={?d}", .{ port, hosts.len, hosts[0], cursor });

    var client = zat.FirehoseClient.init(io, allocator, .{ .hosts = hosts, .cursor = cursor });
    defer client.deinit();

    var handler = Handler{ .allocator = allocator, .channel = &channel, .cursor_path = path };
    try client.subscribe(&handler);
}
