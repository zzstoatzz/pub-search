const std = @import("std");
const Allocator = std.mem.Allocator;
const Client = @import("Client.zig");
const zug = @import("zug");
const logfire = @import("logfire");

const MigrationConn = @import("zug_conn.zig").MigrationConn;
const migrations = @import("migrations.zig").migrations;

/// Initialize schema and run migrations via zug.
///
/// On first deploy against an existing turso instance, `bootstrapIfNeeded`
/// seeds `zug_migrations` with every migration marked already-applied, so
/// `zug.sqlite.run` does no work. On subsequent deploys, only newly-appended
/// migrations run. On a fresh database (no `documents` table), the bootstrap
/// is skipped and `zug.sqlite.run` runs every migration from scratch.
pub fn init(allocator: Allocator, client: *Client) !void {
    try bootstrapIfNeeded(allocator, client);

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

/// If the schema is already in place but `zug_migrations` doesn't exist yet,
/// seed it with every migration marked clean+applied. The current production
/// schema *is* the result of running migrations 001..N — running them again
/// would re-do the 5+ minutes of full-table scans we're trying to escape.
fn bootstrapIfNeeded(allocator: Allocator, client: *Client) !void {
    if (!try tableExists(client, "documents")) return; // fresh DB; let zug create everything
    if (try tableExists(client, "zug_migrations")) return; // already bootstrapped

    logfire.info("zug bootstrap: seeding zug_migrations with {d} migrations as already-applied", .{migrations.len});

    var conn = MigrationConn.init(client);

    // create the migrations table with the same schema zug uses internally,
    // so the rows we INSERT are interpreted correctly when zug.sqlite.run
    // queries it on the next line.
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

    for (migrations) |m| {
        var checksum_buf: [16]u8 = undefined;
        const checksum = m.checksumHex(&checksum_buf);
        try conn.exec(
            "INSERT INTO zug_migrations (id, name, checksum, class, dirty) VALUES (?, ?, ?, ?, ?)",
            .{ m.id, m.name, checksum, @tagName(m.class), @as(i64, 0) },
        );
    }

    _ = allocator; // unused for now — zug.sqlite.run will allocate later
}

fn tableExists(client: *Client, table: []const u8) !bool {
    var res = try client.queryRuntime(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
        &.{.{ .text = table }},
    );
    defer res.deinit();
    return !res.isEmpty();
}

// re-export migration ids and names for callers that want to inspect what
// would run (e.g. a /admin/migrations endpoint someday).
pub const Migration = zug.Migration;
pub const all_migrations: []const zug.Migration = &migrations;
