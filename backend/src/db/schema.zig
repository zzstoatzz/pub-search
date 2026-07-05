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
/// On an existing turso DB (one that has `documents` already), `zug.sqlite.baseline`
/// seeds and verifies the *baseline* migrations marked already-applied — the ones
/// that existed at the moment of zug adoption. `zug.sqlite.run` then only executes
/// migrations appended after adoption. On a fresh DB (no `documents`), baseline is
/// skipped entirely and `run` creates everything from scratch.
pub fn init(allocator: Allocator, client: *Client) !void {
    var conn = MigrationConn.init(client);
    var diag: zug.Diagnostics = .{};

    if (try existingAppSchema(client)) {
        // Mark the first BOOTSTRAP_BASELINE_COUNT migrations as already-applied.
        // baseline() handles CREATE-IF-NOT-EXISTS, INSERT OR IGNORE seeding (so a
        // partial previous attempt completes on the next boot), and post-seed
        // verification of every baseline row's checksum + dirty flag. On
        // already-bootstrapped DBs this short-circuits after verification.
        // BOOTSTRAP_BASELINE_COUNT is FROZEN at the count at adoption time —
        // never grows — so a restored pre-zug backup gets exactly the right
        // historical migrations pre-applied and everything after runs normally.
        zug.sqlite.baseline(allocator, &conn, migrations[0..BOOTSTRAP_BASELINE_COUNT], .{
            .diagnostics = &diag,
        }) catch |err| {
            logfire.err(
                "schema baseline failed: {s} | id={s} | {s}",
                .{ @errorName(err), diag.migration_id, diag.message },
            );
            return err;
        };
    }

    zug.sqlite.run(allocator, &conn, &migrations, .{ .diagnostics = &diag }) catch |err| {
        logfire.err(
            "schema migration failed: {s} | id={s} stmt#{d} preview={s} | {s}",
            .{ @errorName(err), diag.migration_id, diag.statement_index, diag.statement_preview, diag.message },
        );
        return err;
    };

    std.debug.print("schema initialized\n", .{});
}

/// App-specific predicate: does this turso DB already have pub-search's
/// schema? Used to distinguish "fresh DB — let zug create everything" from
/// "existing pre-zug DB — record baseline migrations as already-applied so
/// zug doesn't re-run them." `documents` is the load-bearing table; if it
/// exists the schema is in place.
///
/// Per the zug v0.1.1-alpha.0 contract, `zug.sqlite.baseline` does not
/// decide fresh-vs-existing — it always tries to seed + verify. We gate
/// the call behind this predicate so a fresh DB doesn't get a phantom
/// "applied" migration table without the actual schema underneath.
fn existingAppSchema(client: *Client) !bool {
    var res = try client.queryRuntime(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
        &.{.{ .text = "documents" }},
    );
    defer res.deinit();
    return !res.isEmpty();
}
