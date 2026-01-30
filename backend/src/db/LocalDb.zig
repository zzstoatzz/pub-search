//! Local SQLite read replica using zqlite
//! Provides fast FTS5 queries while Turso remains source of truth

const std = @import("std");
const posix = std.posix;
const zqlite = @import("zqlite");
const Allocator = std.mem.Allocator;
const logfire = @import("logfire");

const LocalDb = @This();

conn: ?zqlite.Conn = null,
allocator: Allocator,
is_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
needs_resync: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
mutex: std.Thread.Mutex = .{},
path: []const u8 = "",
consecutive_errors: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

pub fn init(allocator: Allocator) LocalDb {
    return .{ .allocator = allocator };
}

/// Check database integrity and return false if corrupt
fn checkIntegrity(self: *LocalDb) bool {
    const c = self.conn orelse return false;
    const row = c.row("PRAGMA integrity_check", .{}) catch return false;
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
    std.fs.cwd().deleteFile(path) catch {};
    // also delete WAL and SHM files
    var wal_buf: [260]u8 = undefined;
    var shm_buf: [260]u8 = undefined;
    if (path.len < 252) {
        const wal_path = std.fmt.bufPrint(&wal_buf, "{s}-wal", .{path}) catch return;
        const shm_path = std.fmt.bufPrint(&shm_buf, "{s}-shm", .{path}) catch return;
        std.fs.cwd().deleteFile(wal_path) catch {};
        std.fs.cwd().deleteFile(shm_path) catch {};
    }
}

pub fn open(self: *LocalDb) !void {
    const path_env = posix.getenv("LOCAL_DB_PATH") orelse "/data/local.db";
    self.path = path_env;

    try self.openDb(path_env, false);
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
        std.debug.print("local db: failed to open: {}\n", .{err});
        return err;
    };

    // enable WAL for better concurrency
    _ = self.conn.?.exec("PRAGMA journal_mode=WAL", .{}) catch {};
    _ = self.conn.?.exec("PRAGMA busy_timeout=5000", .{}) catch {};

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

    // documents table (no embedding column - vectors stay on Turso)
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
        \\  indexed_at TEXT
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
        \\  source_collection TEXT
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

    // similarity cache (local copy for fast lookups)
    c.exec(
        \\CREATE TABLE IF NOT EXISTS similarity_cache (
        \\  source_uri TEXT PRIMARY KEY,
        \\  results TEXT NOT NULL,
        \\  doc_count INTEGER NOT NULL,
        \\  computed_at INTEGER NOT NULL
        \\)
    , .{}) catch {};

    // migrations for existing local DBs
    c.exec("ALTER TABLE documents ADD COLUMN indexed_at TEXT", .{}) catch {};
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

/// Execute a SELECT query with comptime SQL, returns row iterator
pub fn query(self: *LocalDb, comptime sql: []const u8, args: anytype) !Rows {
    const span = logfire.span("db.local.query", .{
        .sql = truncateSql(sql),
    });
    defer span.end();

    self.mutex.lock();
    defer self.mutex.unlock();

    const c = self.conn orelse return error.NotOpen;
    const rows = c.rows(sql, args) catch |e| {
        logfire.err("db.local.query failed: {s} | sql: {s}", .{ @errorName(e), truncateSql(sql) });
        return e;
    };
    return .{ .inner = rows };
}

/// Execute a SELECT query expecting single row
pub fn queryOne(self: *LocalDb, comptime sql: []const u8, args: anytype) !?Row {
    const span = logfire.span("db.local.query", .{
        .sql = truncateSql(sql),
    });
    defer span.end();

    self.mutex.lock();
    defer self.mutex.unlock();

    const c = self.conn orelse return error.NotOpen;
    const row = c.row(sql, args) catch |e| {
        logfire.err("db.local.queryOne failed: {s} | sql: {s}", .{ @errorName(e), truncateSql(sql) });
        return e;
    };
    if (row) |r| {
        return .{ .stmt = r };
    }
    return null;
}

/// Execute a statement (INSERT, UPDATE, DELETE)
pub fn exec(self: *LocalDb, comptime sql: []const u8, args: anytype) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

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
    self.mutex.lock();
}

/// Unlock after batch operations
pub fn unlock(self: *LocalDb) void {
    self.mutex.unlock();
}

fn truncateSql(sql: []const u8) []const u8 {
    const max_len = 100;
    return if (sql.len > max_len) sql[0..max_len] else sql;
}
