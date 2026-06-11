//! Local SQLite read replica using zqlite
//! Provides fast FTS5 queries while Turso remains source of truth

const std = @import("std");
const Io = std.Io;
const zqlite = @import("zqlite");
const Allocator = std.mem.Allocator;
const logfire = @import("logfire");

const LocalDb = @This();

/// Local replica schema generation. Bump when createSchema changes shape
/// (new column/table/index the serving code depends on). The builder stamps
/// it into the manifest; the promote watcher rejects a mismatch — a snapshot
/// built by an out-of-date builder image must stall freshness, not break
/// serving. (Scheduled builder machines pin their creation image: recreate
/// them after bumping this.)
pub const SCHEMA_VERSION: u32 = 1;

const READ_POOL_SIZE = 4;

conn: ?zqlite.Conn = null,
read_conn: ?zqlite.Conn = null, // legacy single read conn (kept as pool[0] alias)
// READ POOL: WAL supports concurrent readers natively. A single shared read
// connection serializes ALL reads — a 6s cache-refresh GROUP BY convoyed
// every search behind it, once per refresh tick (2026-06-10, the last flap).
read_pool: [READ_POOL_SIZE]?zqlite.Conn = .{null} ** READ_POOL_SIZE,
read_next: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
allocator: Allocator,
io: Io,
is_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
needs_resync: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
mutex: Io.Mutex = Io.Mutex.init, // protects write conn only
path: []const u8 = "",
consecutive_errors: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

pub fn init(allocator: Allocator, io: Io) LocalDb {
    return .{ .allocator = allocator, .io = io };
}

/// Check database integrity and return false if corrupt. quick_check, not
/// integrity_check: the full check scans every index b-tree, which on a
/// 365MB+ file on a fly volume is minutes of is_ready=false at every boot
/// (keyword falls back to slow turso the whole time). Adopted snapshots are
/// already sha256-gated before they become local.db, so the full scan is
/// redundant; quick_check still catches page-level corruption in seconds.
fn checkIntegrity(self: *LocalDb) bool {
    const c = self.conn orelse return false;
    const row = c.row("PRAGMA quick_check", .{}) catch return false;
    if (row) |r| {
        defer r.deinit();
        const result = r.text(0);
        if (std.mem.eql(u8, result, "ok")) {
            return true;
        }
        std.debug.print("local db: integrity check failed: {s}\n", .{result});
        return false;
    }
    return false;
}

/// Delete the database file and WAL/SHM files
fn deleteDbFiles(path: []const u8) void {
    unlinkPath(path);
    // also delete WAL and SHM files
    var wal_buf: [260]u8 = undefined;
    var shm_buf: [260]u8 = undefined;
    if (path.len < 252) {
        const wal_path = std.fmt.bufPrint(&wal_buf, "{s}-wal", .{path}) catch return;
        const shm_path = std.fmt.bufPrint(&shm_buf, "{s}-shm", .{path}) catch return;
        unlinkPath(wal_path);
        unlinkPath(shm_path);
    }
}

/// Delete a file by path using C unlink (std.fs.cwd removed in 0.16)
fn unlinkPath(path: []const u8) void {
    var buf: [260]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = std.c.unlink(@ptrCast(&buf));
}

pub fn open(self: *LocalDb) !void {
    const path_env = if (std.c.getenv("LOCAL_DB_PATH")) |p| std.mem.span(p) else "/data/local.db";
    try self.openAt(path_env);
}

/// Open at an explicit path — the snapshot builder targets a scratch file,
/// never the serving replica.
pub fn openAt(self: *LocalDb, path: []const u8) !void {
    self.path = path;
    adoptPending(path);
    try self.openDb(path, false);
}

/// Snapshot adoption: if `<path>.new` exists at boot, rename it over the live
/// file (plus clear stale WAL/SHM) before opening. This is how offline-built
/// replicas ship: stage as .new while the old process serves, restart, and
/// the swap is atomic — the serving path never coexists with a bulk writer.
/// The displaced live file is kept as `<path>.prev` (with its manifest
/// sidecar) so rollback is `mv .prev .new` + restart, no re-download.
fn adoptPending(path_env: []const u8) void {
    var new_buf: [256]u8 = undefined;
    const new_path = std.fmt.bufPrintZ(&new_buf, "{s}.new", .{path_env}) catch return;
    var cur_buf: [256]u8 = undefined;
    const cur_path = std.fmt.bufPrintZ(&cur_buf, "{s}", .{path_env}) catch return;

    const fd = std.c.open(new_path.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return; // nothing pending
    _ = std.c.close(fd);

    var aux_buf: [264]u8 = undefined;
    inline for (.{ "-wal", "-shm" }) |suffix| {
        const aux = std.fmt.bufPrintZ(&aux_buf, "{s}{s}", .{ path_env, suffix }) catch return;
        _ = std.c.unlink(aux.ptr);
    }

    // keep the displaced snapshot for rollback: live -> .prev (best-effort)
    var prev_buf: [256]u8 = undefined;
    if (std.fmt.bufPrintZ(&prev_buf, "{s}.prev", .{path_env})) |prev_path| {
        _ = std.c.rename(cur_path.ptr, prev_path.ptr);
    } else |_| {}

    // manifest sidecars follow their snapshots (promote watcher writes them;
    // manual swaps without sidecars are fine — these renames just fail)
    var sc_a: [280]u8 = undefined;
    var sc_b: [280]u8 = undefined;
    if (std.fmt.bufPrintZ(&sc_a, "{s}.manifest.json", .{path_env})) |live_sc| {
        if (std.fmt.bufPrintZ(&sc_b, "{s}.prev.manifest.json", .{path_env})) |prev_sc| {
            _ = std.c.rename(live_sc.ptr, prev_sc.ptr);
        } else |_| {}
    } else |_| {}
    if (std.fmt.bufPrintZ(&sc_a, "{s}.new.manifest.json", .{path_env})) |new_sc| {
        if (std.fmt.bufPrintZ(&sc_b, "{s}.manifest.json", .{path_env})) |live_sc| {
            _ = std.c.rename(new_sc.ptr, live_sc.ptr);
        } else |_| {}
    } else |_| {}

    if (std.c.rename(new_path.ptr, cur_path.ptr) == 0) {
        std.debug.print("local db: adopted pending snapshot {s}\n", .{new_path});
    } else {
        std.debug.print("local db: snapshot adopt FAILED, serving existing file\n", .{});
    }
}

fn openDb(self: *LocalDb, path_env: []const u8, is_retry: bool) !void {
    // convert to null-terminated for zqlite
    var path_buf: [256]u8 = undefined;
    if (path_env.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path_env.len], path_env);
    path_buf[path_env.len] = 0;
    const path: [*:0]const u8 = path_buf[0..path_env.len :0];

    std.debug.print("local db: opening {s}\n", .{path_env});

    const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite;
    self.conn = zqlite.open(path, flags) catch |err| {
        std.debug.print("local db: failed to open write conn: {}\n", .{err});
        return err;
    };

    // enable WAL for better concurrency
    _ = self.conn.?.exec("PRAGMA journal_mode=WAL", .{}) catch {};
    _ = self.conn.?.exec("PRAGMA busy_timeout=5000", .{}) catch {};

    // open the read POOL — WAL mode allows concurrent reads + writes
    for (&self.read_pool) |*slot| {
        const rc = zqlite.open(path, zqlite.OpenFlags.ReadOnly) catch |err| {
            std.debug.print("local db: failed to open read conn: {}\n", .{err});
            return err;
        };
        _ = rc.exec("PRAGMA busy_timeout=1000", .{}) catch {};
        // mmap for fast reads — avoids pread() syscalls, uses OS page cache directly
        _ = rc.exec("PRAGMA mmap_size=268435456", .{}) catch {};
        // 20MB page cache per conn — keeps FTS5 index pages hot across queries
        _ = rc.exec("PRAGMA cache_size=-20000", .{}) catch {};
        slot.* = rc;
    }
    self.read_conn = self.read_pool[0];

    // check integrity - if corrupt, delete and recreate
    if (!self.checkIntegrity()) {
        if (is_retry) {
            std.debug.print("local db: still corrupt after recreation, giving up\n", .{});
            return error.DatabaseCorrupt;
        }
        std.debug.print("local db: corrupt, deleting and recreating\n", .{});
        if (self.conn) |c| c.close();
        self.conn = null;
        deleteDbFiles(path_env);
        return self.openDb(path_env, true);
    }

    try self.createSchema();
    std.debug.print("local db: initialized\n", .{});
}

pub fn deinit(self: *LocalDb) void {
    for (&self.read_pool) |*slot| {
        if (slot.*) |c| c.close();
        slot.* = null;
    }
    self.read_conn = null;
    if (self.conn) |c| c.close();
    self.conn = null;
}

pub fn isReady(self: *LocalDb) bool {
    return self.is_ready.load(.acquire);
}

pub fn setReady(self: *LocalDb, ready: bool) void {
    self.is_ready.store(ready, .release);
}

fn createSchema(self: *LocalDb) !void {
    const c = self.conn orelse return error.NotOpen;

    // documents table (no embedding/embedded_at — vectors are in turbopuffer)
    c.exec(
        \\CREATE TABLE IF NOT EXISTS documents (
        \\  uri TEXT PRIMARY KEY,
        \\  did TEXT NOT NULL,
        \\  rkey TEXT NOT NULL,
        \\  title TEXT NOT NULL,
        \\  content TEXT NOT NULL,
        \\  created_at TEXT,
        \\  publication_uri TEXT,
        \\  platform TEXT DEFAULT 'leaflet',
        \\  source_collection TEXT,
        \\  path TEXT,
        \\  base_path TEXT DEFAULT '',
        \\  has_publication INTEGER DEFAULT 0,
        \\  indexed_at TEXT,
        \\  cover_image TEXT DEFAULT ''
        \\)
    , .{}) catch |err| {
        std.debug.print("local db: failed to create documents table: {}\n", .{err});
        return err;
    };

    // FTS5 index (unicode61 tokenizer to match Turso)
    c.exec(
        \\CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(
        \\  uri UNINDEXED,
        \\  title,
        \\  content,
        \\  tokenize='unicode61'
        \\)
    , .{}) catch |err| {
        std.debug.print("local db: failed to create documents_fts: {}\n", .{err});
        return err;
    };

    // publications table (no created_at - matches Turso schema)
    c.exec(
        \\CREATE TABLE IF NOT EXISTS publications (
        \\  uri TEXT PRIMARY KEY,
        \\  did TEXT NOT NULL,
        \\  rkey TEXT NOT NULL,
        \\  name TEXT NOT NULL,
        \\  description TEXT,
        \\  base_path TEXT,
        \\  platform TEXT DEFAULT 'leaflet',
        \\  source_collection TEXT,
        \\  indexed_at TEXT
        \\)
    , .{}) catch |err| {
        std.debug.print("local db: failed to create publications table: {}\n", .{err});
        return err;
    };

    // publications FTS
    c.exec(
        \\CREATE VIRTUAL TABLE IF NOT EXISTS publications_fts USING fts5(
        \\  uri UNINDEXED,
        \\  name,
        \\  description,
        \\  base_path,
        \\  tokenize='unicode61'
        \\)
    , .{}) catch |err| {
        std.debug.print("local db: failed to create publications_fts: {}\n", .{err});
        return err;
    };

    // document_tags table
    c.exec(
        \\CREATE TABLE IF NOT EXISTS document_tags (
        \\  document_uri TEXT NOT NULL,
        \\  tag TEXT NOT NULL,
        \\  PRIMARY KEY (document_uri, tag)
        \\)
    , .{}) catch |err| {
        std.debug.print("local db: failed to create document_tags table: {}\n", .{err});
        return err;
    };

    // index for tag queries
    c.exec("CREATE INDEX IF NOT EXISTS idx_document_tags_tag ON document_tags(tag)", .{}) catch {};

    // index for base_path join (documents → publications via publication_uri)
    c.exec("CREATE INDEX IF NOT EXISTS idx_documents_publication_uri ON documents(publication_uri)", .{}) catch {};

    // sync metadata table
    c.exec(
        \\CREATE TABLE IF NOT EXISTS sync_meta (
        \\  key TEXT PRIMARY KEY,
        \\  value TEXT
        \\)
    , .{}) catch |err| {
        std.debug.print("local db: failed to create sync_meta table: {}\n", .{err});
        return err;
    };

    // stats table for local counters
    c.exec(
        \\CREATE TABLE IF NOT EXISTS stats (
        \\  id INTEGER PRIMARY KEY CHECK (id = 1),
        \\  total_searches INTEGER DEFAULT 0,
        \\  total_errors INTEGER DEFAULT 0,
        \\  service_started_at INTEGER
        \\)
    , .{}) catch {};
    c.exec("INSERT OR IGNORE INTO stats (id) VALUES (1)", .{}) catch {};

    // popular searches
    c.exec(
        \\CREATE TABLE IF NOT EXISTS popular_searches (
        \\  query TEXT PRIMARY KEY,
        \\  count INTEGER DEFAULT 1
        \\)
    , .{}) catch {};

    // Idempotent column-add for existing local DBs. SQLite returns an error
    // when the column already exists ("duplicate column name"), which is
    // the common case — we'd flood logs if every boot warned on that. So
    // detect the column first via PRAGMA table_info and skip if present,
    // and on the rare ACTUAL failure log loudly.
    addColumnIfMissing(c, "documents", "indexed_at", "TEXT");
    addColumnIfMissing(c, "documents", "embedded_at", "TEXT");
    addColumnIfMissing(c, "documents", "cover_image", "TEXT DEFAULT ''");
    addColumnIfMissing(c, "documents", "is_bridgyfed", "INTEGER DEFAULT 0");
    addColumnIfMissing(c, "documents", "url_dead", "INTEGER DEFAULT 0");
    addColumnIfMissing(c, "publications", "indexed_at", "TEXT");
}

fn hasColumn(c: zqlite.Conn, table: []const u8, column: []const u8) bool {
    var buf: [128]u8 = undefined;
    const sql = std.fmt.bufPrint(&buf, "PRAGMA table_info({s})", .{table}) catch return false;
    var rows = c.rows(sql, .{}) catch return false;
    defer rows.deinit();
    while (rows.next()) |row| {
        if (std.mem.eql(u8, row.text(1), column)) return true;
    }
    return false;
}

fn addColumnIfMissing(c: zqlite.Conn, table: []const u8, column: []const u8, decl: []const u8) void {
    if (hasColumn(c, table, column)) return;
    var buf: [256]u8 = undefined;
    const sql = std.fmt.bufPrint(&buf, "ALTER TABLE {s} ADD COLUMN {s} {s}", .{ table, column, decl }) catch {
        std.debug.print("local db: ALTER format failed for {s}.{s}\n", .{ table, column });
        return;
    };
    c.exec(sql, .{}) catch |err| {
        // Hit only on actual failures (lock contention, disk full) since
        // we pre-checked for duplicate-column. Worth knowing about.
        std.debug.print("local db: ALTER TABLE {s} ADD COLUMN {s} failed: {}\n", .{ table, column, err });
    };
}

/// Row adapter matching result.Row interface (column-indexed access)
pub const Row = struct {
    stmt: zqlite.Row,

    pub fn text(self: Row, index: usize) []const u8 {
        return self.stmt.text(index);
    }

    pub fn int(self: Row, index: usize) i64 {
        return self.stmt.int(index);
    }
};

/// Iterator for query results
pub const Rows = struct {
    inner: zqlite.Rows,

    pub fn next(self: *Rows) ?Row {
        if (self.inner.next()) |r| {
            return .{ .stmt = r };
        }
        return null;
    }

    pub fn deinit(self: *Rows) void {
        self.inner.deinit();
    }

    pub fn err(self: *Rows) ?anyerror {
        return self.inner.err;
    }
};

/// Execute a SELECT query using the read connection (never blocked by writes)
pub fn query(self: *LocalDb, comptime sql: []const u8, args: anytype) !Rows {
    const span = logfire.span("db.local.query", .{
        .sql = truncateSql(sql),
    });
    defer span.end();

    const idx = self.read_next.fetchAdd(1, .monotonic) % READ_POOL_SIZE;
    const c = self.read_pool[idx] orelse return error.NotOpen;
    const rows = c.rows(sql, args) catch |e| {
        logfire.err("db.local.query failed: {s} | sql: {s}", .{ @errorName(e), truncateSql(sql) });
        return e;
    };
    return .{ .inner = rows };
}

/// Execute a statement (INSERT, UPDATE, DELETE)
pub fn exec(self: *LocalDb, comptime sql: []const u8, args: anytype) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const c = self.conn orelse return error.NotOpen;
    c.exec(sql, args) catch |e| {
        logfire.err("db.local.exec failed: {s} | sql: {s}", .{ @errorName(e), truncateSql(sql) });
        return e;
    };
}

/// Get raw connection for batch operations (caller must handle locking)
pub fn getConn(self: *LocalDb) ?zqlite.Conn {
    return self.conn;
}

/// Lock for batch operations
pub fn lock(self: *LocalDb) void {
    self.mutex.lockUncancelable(self.io);
}

/// Unlock after batch operations
pub fn unlock(self: *LocalDb) void {
    self.mutex.unlock(self.io);
}

fn truncateSql(sql: []const u8) []const u8 {
    const max_len = 100;
    return if (sql.len > max_len) sql[0..max_len] else sql;
}


test "adoptPending keeps previous snapshot and moves manifest sidecars" {
    const tio = std.Options.debug_io;
    _ = std.c.mkdir("/tmp/leaflet-adopt-test", 0o755);
    const base = "/tmp/leaflet-adopt-test/local.db";

    const writeStr = struct {
        fn f(io_: Io, path: []const u8, content: []const u8) !void {
            const file = try Io.Dir.createFileAbsolute(io_, path, .{ .truncate = true });
            defer file.close(io_);
            var wbuf: [64]u8 = undefined;
            var fw = Io.File.Writer.init(file, io_, &wbuf);
            try fw.interface.writeAll(content);
            try fw.interface.flush();
        }
    }.f;
    const readStr = struct {
        fn f(io_: Io, path: []const u8, buf: []u8) ![]const u8 {
            const file = try Io.Dir.openFileAbsolute(io_, path, .{});
            defer file.close(io_);
            const n = file.readStreaming(io_, &.{buf}) catch |err| switch (err) {
                error.EndOfStream => return buf[0..0],
                else => return err,
            };
            return buf[0..n];
        }
    }.f;

    try writeStr(tio, base, "OLD");
    try writeStr(tio, base ++ ".manifest.json", "{\"old\":1}");
    try writeStr(tio, base ++ ".new", "NEW");
    try writeStr(tio, base ++ ".new.manifest.json", "{\"new\":1}");

    adoptPending(base);

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("NEW", try readStr(tio, base, &buf));
    try std.testing.expectEqualStrings("OLD", try readStr(tio, base ++ ".prev", &buf));
    try std.testing.expectEqualStrings("{\"new\":1}", try readStr(tio, base ++ ".manifest.json", &buf));
    try std.testing.expectEqualStrings("{\"old\":1}", try readStr(tio, base ++ ".prev.manifest.json", &buf));

    // .new is consumed
    const fd = std.c.open(base ++ ".new", .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    try std.testing.expect(fd < 0);

    // cleanup so reruns start fresh
    inline for (.{ base, base ++ ".prev", base ++ ".manifest.json", base ++ ".prev.manifest.json" }) |path| {
        var zbuf: [128]u8 = undefined;
        const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch unreachable;
        _ = std.c.unlink(z.ptr);
    }
}
