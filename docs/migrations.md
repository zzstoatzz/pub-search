# schema migrations

pub-search runs Turso schema migrations via [zug](https://tangled.sh/@zzstoatzz.io/zug), a small Zig 0.16 SQLite migration runner. Migrations are ordered, recorded in a `zug_migrations` table, run-once-and-checksummed, and halt on dirty failures.

## the system at a glance

```
backend/src/db/
├── migrations.zig    # the ordered Migration list — single source of truth
├── schema.zig        # bootstrap + zug.sqlite.run dispatch
├── zug_conn.zig      # adapter: *Client → zug-shaped connection trait
└── Client.zig        # Turso HTTP client (now with runtime-SQL escape hatch)
```

`db.initSchema()` (from `backend/src/db.zig`) runs in the `initServices` background thread on every backend boot. It calls `schema.init(allocator, client)` which:

1. **Bootstraps `zug_migrations` if needed** (existing-DB-first-deploy case) — see below
2. Calls `zug.sqlite.run(allocator, &conn, &migrations, …)` with our `MigrationConn` adapter
3. zug iterates migrations, skipping any whose `id` is already in `zug_migrations` with a matching checksum

On steady state (post-bootstrap, no new migrations added), step 3 is a single `SELECT id, checksum, dirty FROM zug_migrations` plus in-memory checksum compare. No turso work. Boot is fast.

## the bootstrap — why and how

### why

We adopted zug after the schema had already grown ~51 idempotent ALTER/UPDATE statements that re-ran on every boot. Many were full-table scans against turso (`UPDATE documents SET platform = ... WHERE platform IS NULL` over 15k rows). The cumulative cost was ~5 minutes per boot, during which:

- the local SQLite replica wasn't open yet (gated behind `initSchema` finishing)
- handlers fell back to turso
- turso was busy with the migrations
- requests piled up, fly proxy timed out at 30s

That had bitten us repeatedly (notably 2026-04-04 and 2026-05-04). Each cold start meant 5+ minutes of degraded service.

### how

`schema.zig:bootstrapIfNeeded` handles three states:

| state | how detected | what happens |
|---|---|---|
| fresh DB | `documents` table doesn't exist | skip bootstrap; let `zug.sqlite.run` create everything from migration 001 onward |
| already-bootstrapped | `baselineComplete()` returns true (every baseline id present with right checksum and `dirty=0`) | skip bootstrap; `zug.sqlite.run` is a no-op for the baseline |
| pre-zug DB | `documents` exists but baseline not complete | seed the baseline as already-applied |

The seed loop uses `INSERT OR IGNORE` so a partial previous attempt resumes: rows already in the table stay, missing ones get filled. After seeding, `baselineComplete()` runs again as a verification gate. If it still fails, `init()` halts with `error.BootstrapIncomplete` — better to refuse to start than silently let zug re-run history.

### what counts as "baseline"

`migrations.zig` exports `BOOTSTRAP_BASELINE_COUNT: usize = 10`. **This number is frozen at the count that existed when zug was adopted.** Migrations appended after adoption (011, 012, …) are NOT folded into the baseline — they need to actually run against turso. If a fresh-but-pre-zug DB ever bootstraps (e.g. a restored backup), only baseline entries are pre-marked applied; everything past `BOOTSTRAP_BASELINE_COUNT` runs through `zug.sqlite.run` normally.

A test asserts `BOOTSTRAP_BASELINE_COUNT <= migrations.len`, so accidentally shrinking the array fails the build.

## adding a new migration

1. Append a new entry to `migrations.zig`. Use the next 3-digit prefix (e.g. `011_*`) — the test enforces this.
2. **Do NOT** change `BOOTSTRAP_BASELINE_COUNT`. It stays at 10 forever.
3. **Do NOT** edit any existing migration. zug stores the checksum (Wyhash of `id`, `name`, `class`, `sql`, has-callback flag); a content change trips `ChecksumMismatch` and zug refuses to run.
4. Run `zig build test` to verify. The test suite includes id-uniqueness and 3-digit-prefix assertions.
5. Deploy. zug applies the new migration on next backend boot, recording it in `zug_migrations`.

### transactions

All migrations are `transactional: false`. The Turso HTTP client closes the connection at the end of each pipeline request, so `BEGIN` / `COMMIT` cannot span multiple `conn.exec` calls — wrapping in a transaction would not work.

If a migration fails partway through its statement list, zug marks the row `dirty=1` and refuses to run anything else until repaired. Repair: fix the underlying issue (often a manual SQL cleanup), then `UPDATE zug_migrations SET dirty = 0 WHERE id = '...'` to unblock.

## the adapter (`zug_conn.zig`)

zug's `validateConn` requires a connection with:

```
exec(sql: []const u8, args: anytype) !void
rows(sql: []const u8, args: anytype) !Rows
Rows.next() ?Row
Row.text(i) []const u8
Row.int(i)  i64
```

`MigrationConn` wraps a `*Client` to satisfy this. The tuple → typed-value conversion happens inline at compile time, accepting `[]const u8`, `*const [N:0]u8` (for string literals and `@tagName(enum)`), and `i64` — the exact shapes zug binds. Anything else is a compile error.

The Hrana protocol's value shape requires per-arg type tags (`text`, `integer`, `null`). The runtime-typed path on `Client.zig` (`execRuntime` / `queryRuntime` taking `[]const RuntimeValue`) emits the right tags; the adapter feeds it. Existing comptime-SQL handlers (`Client.exec` / `Client.query`) are untouched.

## ops cheatsheet

```sh
# Inspect migration state on prod (requires turso CLI auth):
turso db shell leaf "SELECT id, checksum, dirty, applied_at FROM zug_migrations ORDER BY id"

# Repair a dirty migration:
#   1. fix the root cause manually (check zug's diagnostics in the boot log)
#   2. UPDATE zug_migrations SET dirty = 0 WHERE id = 'XXX_offending_migration'
#   3. redeploy — zug re-runs the migration body

# Force a re-bootstrap (DANGER — only after verifying schema is intact):
#   DROP TABLE zug_migrations;
#   restart backend
```

## related

- [docs/turso-hrana.md](turso-hrana.md) — the HTTP protocol the Client speaks
- [zug repo](https://tangled.sh/@zzstoatzz.io/zug) — the migration runner library
- `backend/src/db/migrations.zig` — the actual migration list (read this when in doubt)
