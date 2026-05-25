//! Background-refreshed JSON cache, one slot per enum variant.
//!
//! A small thread refreshes every slot on a tick; user requests just dupe the
//! cached body. Read path is constant-time + lock; refresh runs out of band so
//! a slow upstream query (e.g., remote Turso JOIN) never blocks the handler.
//!
//! Designed for endpoints whose backing query is expensive but whose data is
//! tolerant of mild staleness — leaderboards, dashboards.
//!
//! Each instantiation has its own static state (per the generic). Don't share
//! one type across multiple resources; instantiate it per endpoint.

const std = @import("std");
const Io = std.Io;
const logfire = @import("logfire");

/// Cache configuration. `refresh` is called once per slot per tick.
///
/// Default interval is 30 minutes (1800s). Leaderboards are slow-changing
/// by nature — a doc crossing a popularity threshold or a new trending
/// post landing within 30 min of being recommended is plenty fresh.
/// Paired with the CTE-based query rewrite in recommended.zig (which
/// drives from the small recommends table instead of scanning ~18k docs),
/// this brings cache-refresh row reads on Turso into a sane range.
/// Prior values: 45s (too aggressive, dominated the row-read bill);
/// 300s (5 min, still ~91M rows/day).
pub fn Config(comptime Slot: type) type {
    return struct {
        name: []const u8,
        refresh: *const fn (slot: Slot, alloc: std.mem.Allocator) anyerror![]const u8,
        interval_ms: u64 = 1_800_000,
    };
}

pub fn WindowedJsonCache(
    comptime Slot: type,
    comptime cfg: Config(Slot),
) type {
    const slot_count = @typeInfo(Slot).@"enum".fields.len;

    return struct {
        const Entry = struct {
            mu: Io.Mutex = Io.Mutex.init,
            body: ?[]u8 = null, // page_allocator-owned
            fetched_at_ns: i128 = 0,
        };

        var entries: [slot_count]Entry = [_]Entry{.{}} ** slot_count;
        var io_storage: ?Io = null;
        var refresh_thread: ?std.Thread = null;

        /// Spawn the background refresh thread. Returns immediately — the
        /// first refresh runs on the spawned thread so this never blocks the
        /// caller (important: initServices spawns this BEFORE the firehose
        /// consumer; a slow first refresh would otherwise stall ingestion).
        pub fn init(io: Io) void {
            io_storage = io;
            refresh_thread = std.Thread.spawn(.{}, refreshLoop, .{}) catch |err| {
                logfire.warn("{s} cache: refresh thread failed: {}", .{ cfg.name, err });
                return;
            };
            if (refresh_thread) |t| t.detach();
            logfire.info("{s} cache: refreshing every {d}ms", .{ cfg.name, cfg.interval_ms });
        }

        /// `alloc`-duped copy of the cached body for `slot`, or null if the
        /// background thread hasn't populated it yet. Caller owns the slice.
        pub fn snapshot(slot: Slot, alloc: std.mem.Allocator) !?[]u8 {
            const io = io_storage orelse return null;
            const idx = @intFromEnum(slot);
            entries[idx].mu.lockUncancelable(io);
            defer entries[idx].mu.unlock(io);
            if (entries[idx].body) |body| return try alloc.dupe(u8, body);
            return null;
        }

        fn refreshLoop() void {
            const io = io_storage orelse return;
            // first refresh immediately so the cache becomes warm without
            // waiting a full interval.
            refreshAll();
            while (true) {
                io.sleep(Io.Duration.fromMilliseconds(cfg.interval_ms), .awake) catch {};
                refreshAll();
            }
        }

        fn refreshAll() void {
            inline for (@typeInfo(Slot).@"enum".fields) |f| {
                refreshSlot(@as(Slot, @enumFromInt(f.value)));
            }
        }

        fn refreshSlot(slot: Slot) void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const fresh = cfg.refresh(slot, alloc) catch |err| {
                logfire.warn("{s} cache: refresh failed ({s}): {}", .{ cfg.name, @tagName(slot), err });
                return;
            };

            const stored = std.heap.page_allocator.dupe(u8, fresh) catch return;
            const io = io_storage orelse {
                std.heap.page_allocator.free(stored);
                return;
            };
            const now_ns: i128 = Io.Timestamp.now(io, .real).nanoseconds;

            const idx = @intFromEnum(slot);
            entries[idx].mu.lockUncancelable(io);
            defer entries[idx].mu.unlock(io);
            if (entries[idx].body) |old| std.heap.page_allocator.free(old);
            entries[idx].body = stored;
            entries[idx].fetched_at_ns = now_ns;
        }
    };
}
