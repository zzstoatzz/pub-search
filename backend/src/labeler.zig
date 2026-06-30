//! pub-search labeler — serves com.atproto.label.{queryLabels,subscribeLabels}
//! and emits signed `bulk-mirror` account labels.
//!
//! This is the SAME proven serving code as labelz (label.zig + server.zig lifted
//! verbatim; store.zig re-backed on zqlite). The backend already consumes the
//! firehose and holds the corpus, so the labeler lives in-process: a second
//! listener on its own port (LABELER_PORT), started in a background thread.
//!
//! Lifecycle: start() reads env and, only if LABELER_DID is set, opens the store
//! and starts the ws server. emit() builds → signs → stores → broadcasts a
//! label. Without a configured signing key, emit() is a no-op error so the
//! endpoints can serve existing labels read-only before identity is provisioned.

const std = @import("std");
const websocket = @import("websocket");
const zat = @import("zat");
const logfire = @import("logfire");
const label_mod = @import("labeler/label.zig");
const store_mod = @import("labeler/store.zig");
const server_mod = @import("labeler/server.zig");

const Io = std.Io;
const Label = label_mod.Label;
const Keypair = zat.Keypair;
const Store = store_mod.Store;
const Server = server_mod.Server;

pub const LABEL_BULK_MIRROR = "bulk-mirror";

// module-level state — emit() is called from the firehose/admin paths, the
// ws server runs detached, so this outlives start().
var g_io: ?Io = null;
var g_alloc: std.mem.Allocator = undefined;
var g_store: ?*Store = null;
var g_server: ?*Server = null;
var g_keypair: ?Keypair = null;
var g_did: ?[]const u8 = null;

fn getenv(name: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

/// Start the labeler if LABELER_DID is configured. Safe to call once at boot;
/// failures are logged and leave the labeler disabled (the rest of the backend
/// is unaffected).
pub fn start(allocator: std.mem.Allocator, io: Io) void {
    const did = getenv("LABELER_DID") orelse {
        logfire.info("labeler: LABELER_DID unset — labeler disabled", .{});
        return;
    };

    const port: u16 = if (getenv("LABELER_PORT")) |p|
        std.fmt.parseInt(u16, p, 10) catch 3001
    else
        3001;
    const db_path: [*:0]const u8 = if (getenv("LABELER_DB")) |p| @ptrCast(p.ptr) else "/data/labels.db";

    g_io = io;
    g_alloc = allocator;
    g_did = did;

    // optional signing key — present = emit enabled; absent = serve-only.
    if (getenv("LABELER_SECRET_KEY")) |hex| {
        if (hex.len != 64) {
            logfire.err("labeler: LABELER_SECRET_KEY must be 64 hex chars", .{});
        } else {
            var key: [32]u8 = undefined;
            if (std.fmt.hexToBytes(&key, hex)) |_| {
                g_keypair = Keypair.fromSecretKey(.secp256k1, key) catch |err| blk: {
                    logfire.err("labeler: bad signing key: {s}", .{@errorName(err)});
                    break :blk null;
                };
            } else |_| {
                logfire.err("labeler: LABELER_SECRET_KEY invalid hex", .{});
            }
        }
    }

    const store = allocator.create(Store) catch return;
    store.* = Store.init(db_path) catch |err| {
        logfire.err("labeler: store open failed: {s}", .{@errorName(err)});
        allocator.destroy(store);
        return;
    };
    g_store = store;

    const server = allocator.create(Server) catch return;
    server.* = Server.init(allocator, store);
    g_server = server;

    server_mod.init(io);
    const WsHandler = server_mod.Handler(Server);
    var ws = websocket.Server(WsHandler).init(allocator, io, .{
        .port = port,
        .address = "0.0.0.0",
        .max_conn = 256,
        .max_message_size = 64 * 1024,
    }) catch |err| {
        logfire.err("labeler: ws server init failed: {s}", .{@errorName(err)});
        return;
    };

    const thread = ws.listenInNewThread(server) catch |err| {
        logfire.err("labeler: listen failed: {s}", .{@errorName(err)});
        return;
    };
    thread.detach();

    logfire.info("labeler: serving on :{d} (src={s}, emit={s})", .{
        port, did, if (g_keypair == null) "off" else "on",
    });
}

/// Emit (or negate) an account-level label on a subject DID. Returns the
/// assigned sequence number. To retract, call with neg=true and the same
/// (did, val) — per the atproto spec, consumers stop hydrating the original.
/// Returns error.NotConfigured if no signing key / store is set up.
pub fn emit(subject_did: []const u8, val: []const u8, neg: bool) !i64 {
    const keypair = &(g_keypair orelse return error.NotConfigured);
    const store = g_store orelse return error.NotConfigured;
    const server = g_server orelse return error.NotConfigured;
    const did = g_did orelse return error.NotConfigured;
    const io = g_io orelse return error.NotConfigured;

    var ts_buf: [32]u8 = undefined;
    var label = Label{
        .src = did,
        .uri = subject_did,
        .val = val,
        .neg = neg,
        .cts = nowIso8601(io, &ts_buf),
    };

    var sig_buf: [64]u8 = undefined;
    const encoded = try label.signAndEncode(g_alloc, keypair, &sig_buf);
    defer g_alloc.free(encoded);

    const seq = try store.insert(&label, encoded);
    server.broadcast(seq, encoded);
    logfire.info("labeler: emit seq={d} val={s} neg={} uri={s}", .{ seq, val, neg, subject_did });
    return seq;
}

fn nowIso8601(io: Io, buf: *[32]u8) []const u8 {
    const ts_ns = Io.Timestamp.now(io, .real).nanoseconds;
    const ts_secs: u64 = @intCast(@divFloor(ts_ns, std.time.ns_per_s));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = ts_secs };
    const day = epoch.getDaySeconds();
    const yd = epoch.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{
        yd.year,               md.month.numeric(),       md.day_index + 1,
        day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute(),
    }) catch "1970-01-01T00:00:00.000Z";
}
