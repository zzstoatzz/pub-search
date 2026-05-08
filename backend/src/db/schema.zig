const std = @import("std");
const Allocator = std.mem.Allocator;
const Client = @import("Client.zig");
const zug = @import("zug");
const logfire = @import("logfire");

const migrations_mod = @import("migrations.zig");
const MigrationConn = @import("zug_conn.zig").MigrationConn;
const migrations = migrations_mod.migrations;
const BOOTSTRAP_BASELINE_COUNT = migrations_mod.BOOTSTRAP_BASELINE_COUNT;

/// Initialize schema and run migrations via zug.
///
/// On first deploy against an existing turso instance, `bootstrapIfNeeded`
/// seeds `zug_migrations` with the *baseline* migrations marked already-applied
/// (the ones that existed at the moment of zug adoption), so `zug.sqlite.run`
/// only runs migrations appended after adoption. On a fresh DB (no `documents`
/// table), bootstrap is skipped and zug runs everything from scratch.
pub fn init(allocator: Allocator, client: *Client) !void {
    try bootstrapIfNeeded(client);

    var conn = MigrationConn.init(client);
    var diag: zug.Diagnostics = .{};
    zug.sqlite.run(allocator, &conn, &migrations, .{ .diagnostics = &diag }) catch |err| {
        logfire.err(
            "schema migration failed: {s} | id={s} stmt#{d} preview={s} | {s}",
            .{ @errorName(err), diag.migration_id, diag.statement_index, diag.statement_preview, diag.message },
        );
        return err;
    };

    std.debug.print("schema initialized\n", .{});
}

/// Bootstrap zug_migrations on an existing turso DB (one that has `documents`
/// but no `zug_migrations` yet — i.e. the first deploy after zug adoption, or
/// a restored backup taken before adoption).
///
/// **Resumable + verified.** `INSERT OR IGNORE` lets a partial bootstrap from a
/// previous boot complete on the next boot — rows that landed last time stay,
/// missing ones get filled in. After seeding, every baseline id is verified
/// to exist with the matching checksum and `dirty=0`; otherwise this returns
/// `error.BootstrapIncomplete` so `init()` halts loudly instead of silently
/// letting `zug.sqlite.run` re-execute the historical migrations.
///
/// Only `migrations[0..BOOTSTRAP_BASELINE_COUNT]` is seeded. Anything appended
/// later (a new 011, 012, …) is NOT pre-marked applied — those run normally
/// via `zug.sqlite.run`. Otherwise an old pre-zug DB restored from a backup
/// would silently skip every new migration.
fn bootstrapIfNeeded(client: *Client) !void {
    if (!try tableExists(client, "documents")) return; // fresh DB; let zug create everything

    var conn = MigrationConn.init(client);

    // create the migrations table with the same schema zug uses internally so
    // the rows we INSERT are interpreted correctly when zug.sqlite.run reads
    // the table on the next line. CREATE-IF-NOT-EXISTS is a no-op on a DB
    // where bootstrap previously got past this step.
    try conn.exec(
        \\CREATE TABLE IF NOT EXISTS zug_migrations (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  checksum TEXT NOT NULL,
        \\  class TEXT NOT NULL,
        \\  dirty INTEGER NOT NULL DEFAULT 0,
        \\  applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        \\)
    , .{});

    // if the table already has every baseline row with correct checksums,
    // we're done. otherwise seed the missing rows (resumable from a partial
    // previous bootstrap) and verify.
    if (try baselineComplete(client)) return;

    logfire.info(
        "zug bootstrap: seeding {d} baseline migrations as already-applied",
        .{BOOTSTRAP_BASELINE_COUNT},
    );

    const baseline = migrations[0..BOOTSTRAP_BASELINE_COUNT];
    for (baseline) |m| {
        var checksum_buf: [16]u8 = undefined;
        const checksum = m.checksumHex(&checksum_buf);
        // INSERT OR IGNORE: rows that landed in a previous attempt stay; this
        // round only fills holes. (it does NOT fix a corrupted checksum on an
        // existing row — that case is caught by baselineComplete below.)
        try conn.exec(
            "INSERT OR IGNORE INTO zug_migrations (id, name, checksum, class, dirty) VALUES (?, ?, ?, ?, ?)",
            .{ m.id, m.name, checksum, @tagName(m.class), @as(i64, 0) },
        );
    }

    if (!try baselineComplete(client)) {
        logfire.err("zug bootstrap: baseline still incomplete after seeding — refusing to proceed", .{});
        return error.BootstrapIncomplete;
    }
}

/// Returns true iff every baseline migration id is present in `zug_migrations`
/// with matching checksum and `dirty=0`. Used both as a fast-path skip for
/// already-bootstrapped DBs and as a post-seed verification gate.
fn baselineComplete(client: *Client) !bool {
    const baseline = migrations[0..BOOTSTRAP_BASELINE_COUNT];
    for (baseline) |m| {
        var checksum_buf: [16]u8 = undefined;
        const expected_checksum = m.checksumHex(&checksum_buf);

        var res = try client.queryRuntime(
            "SELECT checksum, dirty FROM zug_migrations WHERE id = ? LIMIT 1",
            &.{.{ .text = m.id }},
        );
        defer res.deinit();
        const row = res.first() orelse return false;

        const got_checksum = row.text(0);
        const got_dirty = row.int(1);
        if (!std.mem.eql(u8, got_checksum, expected_checksum)) return false;
        if (got_dirty != 0) return false;
    }
    return true;
}

fn tableExists(client: *Client, table: []const u8) !bool {
    var res = try client.queryRuntime(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
        &.{.{ .text = table }},
    );
    defer res.deinit();
    return !res.isEmpty();
}

