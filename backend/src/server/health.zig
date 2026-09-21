const std = @import("std");
const db = @import("../db.zig");
const promote = @import("../promote.zig");
const jetstream = @import("../ingest/jetstream.zig");

pub const Report = struct {
    ok: bool,
    checked_at: i64,
    snapshot_fresh: bool,
    snapshot_age_seconds: ?i64,
    fts_ok: bool,
    ingest_fresh: bool,
    ingest_age_seconds: ?i64,
    overlay_ready: bool,
};

fn env(name: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

fn snapshotFresh(created: i64, now: i64, enabled: bool, hours: ?[]const u8) bool {
    if (created <= 0 or created > now + 60) return false;
    if (!enabled) return true;
    const raw = hours orelse return now - created <= 180 * 60;
    if (raw.len == 0) return now - created <= 180 * 60;
    var tokens = std.mem.splitScalar(u8, raw, ',');
    while (tokens.next()) |token| {
        const hour = std.fmt.parseInt(u64, std.mem.trim(u8, token, " "), 10) catch return false;
        if (hour > 23) return false;
    }
    const current_hour = @divFloor(now, 3600) * 3600;
    for (1..25) |offset| {
        const start = current_hour - @as(i64, @intCast(offset)) * 3600;
        const hour: u64 = @intCast(@mod(@divFloor(start, 3600), 24));
        if (promote.hoursListContains(raw, hour)) return created >= start - 150 * 60;
    }
    return false;
}

fn snapshotTime(local: *db.LocalDb) !i64 {
    var rows = try local.query("SELECT value FROM sync_meta WHERE key = 'last_sync'", .{});
    defer rows.deinit();
    const row = rows.next() orelse return error.MissingSnapshotTime;
    return std.fmt.parseInt(i64, row.text(0), 10);
}

fn ftsWorks(local: *db.LocalDb) !bool {
    var rows = try local.query("SELECT rowid FROM documents_fts WHERE documents_fts MATCH 'leaflet' LIMIT 1", .{});
    defer rows.deinit();
    return rows.next() != null;
}

fn overlayReady() bool {
    if (!std.mem.eql(u8, env("OVERLAY_SERVE") orelse "0", "1")) return true;
    const overlay = db.getOverlay() orelse return false;
    var rows = overlay.query("SELECT 1 FROM documents_overlay LIMIT 1", .{}) catch return false;
    defer rows.deinit();
    _ = rows.next();
    return rows.inner.err == null;
}

pub fn probe(io: std.Io) Report {
    const now: i64 = @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
    var created: i64 = 0;
    var fts_ok = false;
    if (db.getLocalDb()) |local| {
        created = snapshotTime(local) catch 0;
        fts_ok = ftsWorks(local) catch false;
    }
    const fresh = snapshotFresh(created, now, promote.enabled(), env("PROMOTE_ADOPT_UTC_HOURS"));
    const age = jetstream.progressAgeSeconds(io);
    const ingest_fresh = if (age) |a| a < jetstream.staleSeconds() else false;
    const overlay_ready = overlayReady();
    return .{
        .ok = fresh and fts_ok and ingest_fresh and overlay_ready,
        .checked_at = now,
        .snapshot_fresh = fresh,
        .snapshot_age_seconds = if (created > 0) @max(0, now - created) else null,
        .fts_ok = fts_ok,
        .ingest_fresh = ingest_fresh,
        .ingest_age_seconds = age,
        .overlay_ready = overlay_ready,
    };
}

test "freshness respects closed adoption windows and rejects bad timestamps or policy" {
    const now = 10 * 86400 + 8 * 3600 + 1800;
    const yesterday = 9 * 86400 + 8 * 3600;
    try std.testing.expect(snapshotFresh(yesterday, now, true, "8"));
    try std.testing.expect(!snapshotFresh(yesterday, now + 3600, true, "8"));
    try std.testing.expect(snapshotFresh(now - 150 * 60, now + 3600, true, "8"));
    try std.testing.expect(!snapshotFresh(now - 181 * 60, now, true, null));
    try std.testing.expect(snapshotFresh(now - 180 * 60, now, true, ""));
    try std.testing.expect(!snapshotFresh(now, now, true, "8,bad"));
    try std.testing.expect(!snapshotFresh(now, now, true, "24"));
    try std.testing.expect(!snapshotFresh(0, now, false, null));
    try std.testing.expect(!snapshotFresh(now + 61, now, true, "8"));
    try std.testing.expect(snapshotFresh(yesterday, now, false, null));
}

test "snapshot probe reads real SQLite metadata and detects empty or missing FTS" {
    const zqlite = @import("zqlite");
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var local = db.LocalDb.init(std.testing.allocator, threaded.io());
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite);
    defer conn.close();
    local.read_pool[0] = conn;
    try conn.exec("CREATE TABLE sync_meta (key TEXT PRIMARY KEY, value TEXT)", .{});
    try std.testing.expectError(error.MissingSnapshotTime, snapshotTime(&local));
    try conn.exec("INSERT INTO sync_meta VALUES ('last_sync', '1789893704')", .{});
    try std.testing.expectEqual(@as(i64, 1789893704), try snapshotTime(&local));
    try conn.exec("CREATE VIRTUAL TABLE documents_fts USING fts5(title)", .{});
    try std.testing.expect(!try ftsWorks(&local));
    try conn.exec("INSERT INTO documents_fts VALUES ('a leaflet document')", .{});
    try std.testing.expect(try ftsWorks(&local));
    try conn.exec("DELETE FROM documents_fts", .{});
    try std.testing.expect(!try ftsWorks(&local));
    try conn.exec("DROP TABLE documents_fts", .{});
    if (ftsWorks(&local)) |_| return error.ExpectedProbeFailure else |_| {}
    try conn.exec("UPDATE sync_meta SET value = 'invalid'", .{});
    try std.testing.expectError(error.InvalidCharacter, snapshotTime(&local));
}
