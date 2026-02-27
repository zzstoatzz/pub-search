const std = @import("std");
const posix = std.posix;

const schema = @import("schema.zig");
const result = @import("result.zig");
const sync = @import("sync.zig");

// re-exports
pub const Client = @import("Client.zig");
pub const LocalDb = @import("LocalDb.zig");
pub const Row = result.Row;
pub const Result = result.Result;
pub const BatchResult = result.BatchResult;

// global state
var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var client: ?Client = null;
var sync_client: ?Client = null;
var local_db: ?LocalDb = null;

/// Initialize Turso client only (fast, call synchronously at startup)
pub fn initTurso() !void {
    client = try Client.init(gpa.allocator());
    sync_client = try Client.init(gpa.allocator());
    try schema.init(&client.?);
}

/// Initialize local SQLite replica (slow, call in background thread)
pub fn initLocalDb() void {
    initLocal() catch |err| {
        std.debug.print("local db init failed (will use turso only): {}\n", .{err});
    };
}

fn initLocal() !void {
    // check if local db is disabled
    if (posix.getenv("LOCAL_DB_ENABLED")) |val| {
        if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "0")) {
            std.debug.print("local db disabled via LOCAL_DB_ENABLED\n", .{});
            return;
        }
    }

    local_db = LocalDb.init(gpa.allocator());
    try local_db.?.open();
}

pub fn getClient() ?*Client {
    if (client) |*c| return c;
    return null;
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
pub fn startSync() void {
    const c = if (sync_client) |*sc| sc else {
        std.debug.print("sync: no sync client, skipping\n", .{});
        return;
    };
    const local = getLocalDbRaw() orelse {
        std.debug.print("sync: no local db, skipping\n", .{});
        return;
    };

    const thread = std.Thread.spawn(.{}, syncLoop, .{ c, local }) catch |err| {
        std.debug.print("sync: failed to start thread: {}\n", .{err});
        return;
    };
    thread.detach();
    std.debug.print("sync: background thread started\n", .{});
}

fn syncLoop(turso: *Client, local: *LocalDb) void {
    // full sync on startup — reconciles with Turso and cleans up stale docs
    sync.fullSync(turso, local) catch |err| {
        std.debug.print("sync: initial full sync failed: {}\n", .{err});
    };

    // get sync interval from env (default 5 minutes)
    const interval_secs: u64 = blk: {
        const env_val = posix.getenv("SYNC_INTERVAL_SECS") orelse "300";
        break :blk std.fmt.parseInt(u64, env_val, 10) catch 300;
    };

    std.debug.print("sync: incremental sync every {d} seconds\n", .{interval_secs});

    // periodic incremental sync
    while (true) {
        std.Thread.sleep(interval_secs * std.time.ns_per_s);
        sync.incrementalSync(turso, local) catch |err| {
            std.debug.print("sync: incremental sync failed: {}\n", .{err});
        };
    }
}
