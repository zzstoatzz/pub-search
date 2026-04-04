const std = @import("std");
const Io = std.Io;

const schema = @import("db/schema.zig");
const result = @import("db/result.zig");
const sync = @import("db/sync.zig");

// re-exports
pub const Client = @import("db/Client.zig");
pub const LocalDb = @import("db/LocalDb.zig");
pub const Row = result.Row;
pub const Result = result.Result;
pub const BatchResult = result.BatchResult;

// global state
const allocator = std.heap.smp_allocator;
var client: ?Client = null;
var sync_client: ?Client = null;
var local_db: ?LocalDb = null;

/// Initialize Turso client only (fast, call synchronously at startup).
/// Schema migrations run separately via initSchema() in the background thread
/// so a slow/unreachable turso doesn't block the accept loop.
pub fn initTurso(io: Io) !void {
    client = try Client.init(allocator, io);
    sync_client = try Client.init(allocator, io);
}

/// Run schema migrations (idempotent). Call from background thread.
pub fn initSchema() void {
    if (client) |*c| {
        schema.init(c) catch |err| {
            std.debug.print("schema init failed (tables likely already exist): {}\n", .{err});
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
}

fn syncLoop(turso: *Client, local: *LocalDb, io: Io) void {
    // incremental sync on startup — gets new docs + cleans tombstoned deletions
    // (falls back to full sync automatically if no last_sync exists, i.e., first boot)
    sync.incrementalSync(turso, local) catch |err| {
        std.debug.print("sync: initial sync failed: {}\n", .{err});
    };

    // get sync interval from env (default 5 minutes)
    const interval_secs: u64 = blk: {
        const env_val = if (std.c.getenv("SYNC_INTERVAL_SECS")) |p| std.mem.span(p) else "300";
        break :blk std.fmt.parseInt(u64, env_val, 10) catch 300;
    };

    std.debug.print("sync: incremental sync every {d} seconds\n", .{interval_secs});

    // periodic incremental sync
    while (true) {
        io.sleep(Io.Duration.fromSeconds(@intCast(interval_secs)), .awake) catch {};
        sync.incrementalSync(turso, local) catch |err| {
            std.debug.print("sync: incremental sync failed: {}\n", .{err});
        };
    }
}
