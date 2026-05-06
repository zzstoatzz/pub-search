const std = @import("std");
const Io = std.Io;
const logfire = @import("logfire");

const schema = @import("db/schema.zig");
const result = @import("db/result.zig");
const sync = @import("db/sync.zig");

// re-exports
pub const Client = @import("db/Client.zig");
pub const LocalDb = @import("db/LocalDb.zig");
pub const Row = result.Row;
pub const Result = result.Result;
pub const BatchResult = result.BatchResult;
pub const MigrationConn = @import("db/zug_conn.zig").MigrationConn;

// global state
const allocator = std.heap.smp_allocator;
var client: ?Client = null;
var sync_client: ?Client = null;
var local_db: ?LocalDb = null;

// sync liveness heartbeat (unix seconds). set at the top of each sync loop
// iteration; watchdog thread aborts the process if it goes stale so fly
// restarts us. zig 0.16 http.Client has no timeout, so a wedged HTTP call
// would otherwise silently kill sync forever.
var sync_heartbeat_s = std.atomic.Value(i64).init(0);
var sync_interval_secs_atomic = std.atomic.Value(u64).init(300);

/// Initialize Turso client only (fast, call synchronously at startup).
/// Schema migrations run separately via initSchema() in the background thread
/// so a slow/unreachable turso doesn't block the accept loop.
pub fn initTurso(io: Io) !void {
    client = try Client.init(allocator, io);
    sync_client = try Client.init(allocator, io);
}

/// Run schema migrations via zug. Call from background thread.
///
/// On an existing turso DB, `schema.bootstrapIfNeeded` seeds the
/// `zug_migrations` table on first run so no migrations actually execute.
/// On a fresh DB, the full migration list runs from scratch.
pub fn initSchema() void {
    if (client) |*c| {
        schema.init(allocator, c) catch |err| {
            logfire.err("schema init failed: {s}", .{@errorName(err)});
        };
    }
}

/// Initialize local SQLite replica (slow, call in background thread)
pub fn initLocalDb(io: Io) void {
    initLocal(io) catch |err| {
        std.debug.print("local db init failed (will use turso only): {}\n", .{err});
    };
}

fn initLocal(io: Io) !void {
    // check if local db is disabled
    if (std.c.getenv("LOCAL_DB_ENABLED")) |p| {
        const val = std.mem.span(p);
        if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "0")) {
            std.debug.print("local db disabled via LOCAL_DB_ENABLED\n", .{});
            return;
        }
    }

    local_db = LocalDb.init(allocator, io);
    try local_db.?.open();
}

pub fn getClient() ?*Client {
    if (client) |*c| return c;
    return null;
}

pub fn startKeepalive() void {
    if (client) |*c| c.startKeepalive();
}

/// Get local db if ready (synced and available)
pub fn getLocalDb() ?*LocalDb {
    if (local_db) |*l| {
        if (l.isReady()) return l;
    }
    return null;
}

/// Get local db even if not ready (for sync operations)
pub fn getLocalDbRaw() ?*LocalDb {
    if (local_db) |*l| return l;
    return null;
}

/// Start background sync thread (call from main after db.init)
pub fn startSync(io: Io) void {
    const c = if (sync_client) |*sc| sc else {
        std.debug.print("sync: no sync client, skipping\n", .{});
        return;
    };
    const local = getLocalDbRaw() orelse {
        std.debug.print("sync: no local db, skipping\n", .{});
        return;
    };

    const thread = std.Thread.spawn(.{}, syncLoop, .{ c, local, io }) catch |err| {
        std.debug.print("sync: failed to start thread: {}\n", .{err});
        return;
    };
    thread.detach();
    std.debug.print("sync: background thread started\n", .{});

    const watchdog = std.Thread.spawn(.{}, syncWatchdog, .{io}) catch |err| {
        std.debug.print("sync: failed to start watchdog: {}\n", .{err});
        return;
    };
    watchdog.detach();
    std.debug.print("sync: watchdog thread started\n", .{});
}

fn nowSeconds(io: Io) i64 {
    return @intCast(@divFloor(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
}

fn syncLoop(turso: *Client, local: *LocalDb, io: Io) void {
    // get sync interval from env (default 5 minutes)
    const interval_secs: u64 = blk: {
        const env_val = if (std.c.getenv("SYNC_INTERVAL_SECS")) |p| std.mem.span(p) else "300";
        break :blk std.fmt.parseInt(u64, env_val, 10) catch 300;
    };
    sync_interval_secs_atomic.store(interval_secs, .release);

    // incremental sync on startup — gets new docs + cleans tombstoned deletions
    // (falls back to full sync automatically if no last_sync exists, i.e., first boot)
    sync_heartbeat_s.store(nowSeconds(io), .release);
    sync.incrementalSync(turso, local) catch |err| {
        std.debug.print("sync: initial sync failed: {}\n", .{err});
    };

    std.debug.print("sync: incremental sync every {d} seconds\n", .{interval_secs});

    // periodic incremental sync
    while (true) {
        io.sleep(Io.Duration.fromSeconds(@intCast(interval_secs)), .awake) catch {};
        // update heartbeat before each attempt; a hung HTTP call prevents the
        // next iteration's update, which the watchdog will catch.
        sync_heartbeat_s.store(nowSeconds(io), .release);
        sync.incrementalSync(turso, local) catch |err| {
            std.debug.print("sync: incremental sync failed: {}\n", .{err});
        };
    }
}

/// Watchdog: aborts the process if the sync loop hasn't updated its heartbeat
/// within ~3x the configured sync interval. fly auto-restarts the machine.
fn syncWatchdog(io: Io) void {
    // wait for syncLoop to record its initial interval + heartbeat
    io.sleep(Io.Duration.fromSeconds(30), .awake) catch {};

    while (true) {
        io.sleep(Io.Duration.fromSeconds(60), .awake) catch {};

        const interval = sync_interval_secs_atomic.load(.acquire);
        const heartbeat = sync_heartbeat_s.load(.acquire);
        if (heartbeat == 0) continue; // not started yet

        const now_s = nowSeconds(io);
        const staleness_s: i64 = now_s - heartbeat;
        const max_staleness_s: i64 = @intCast(interval * 3);

        if (staleness_s > max_staleness_s) {
            logfire.err("sync watchdog: heartbeat stale for {d}s (max {d}s) — aborting for restart", .{ staleness_s, max_staleness_s });
            std.debug.print("sync watchdog: heartbeat stale for {d}s (max {d}s) — aborting for restart\n", .{ staleness_s, max_staleness_s });
            std.process.exit(1);
        }
    }
}
