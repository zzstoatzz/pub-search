const std = @import("std");
const Client = @import("Client.zig");

/// Initialize database schema and run migrations
pub fn init(client: *Client) !void {
    try createTables(client);
    try runMigrations(client);
    std.debug.print("schema initialized\n", .{});
}

fn createTables(client: *Client) !void {
    try client.exec(
        \\CREATE TABLE IF NOT EXISTS documents (
        \\  uri TEXT PRIMARY KEY,
        \\  did TEXT NOT NULL,
        \\  rkey TEXT NOT NULL,
        \\  title TEXT NOT NULL,
        \\  content TEXT NOT NULL,
        \\  created_at TEXT,
        \\  publication_uri TEXT
        \\)
    , &.{});

    try client.exec(
        \\CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(
        \\  uri UNINDEXED,
        \\  title,
        \\  content
        \\)
    , &.{});

    try client.exec(
        \\CREATE TABLE IF NOT EXISTS publications (
        \\  uri TEXT PRIMARY KEY,
        \\  did TEXT NOT NULL,
        \\  rkey TEXT NOT NULL,
        \\  name TEXT NOT NULL,
        \\  description TEXT,
        \\  base_path TEXT
        \\)
    , &.{});

    try client.exec(
        \\CREATE VIRTUAL TABLE IF NOT EXISTS publications_fts USING fts5(
        \\  uri UNINDEXED,
        \\  name,
        \\  description
        \\)
    , &.{});

    try client.exec(
        \\CREATE TABLE IF NOT EXISTS document_tags (
        \\  document_uri TEXT NOT NULL,
        \\  tag TEXT NOT NULL,
        \\  PRIMARY KEY (document_uri, tag)
        \\)
    , &.{});

    client.exec(
        "CREATE INDEX IF NOT EXISTS idx_document_tags_tag ON document_tags(tag)",
        &.{},
    ) catch {};

    // stats table: single row for lifetime counters
    try client.exec(
        \\CREATE TABLE IF NOT EXISTS stats (
        \\  id INTEGER PRIMARY KEY CHECK (id = 1),
        \\  total_searches INTEGER DEFAULT 0,
        \\  total_errors INTEGER DEFAULT 0,
        \\  service_started_at INTEGER
        \\)
    , &.{});

    // ensure the single row exists
    client.exec("INSERT OR IGNORE INTO stats (id) VALUES (1)", &.{}) catch {};

    // set service_started_at if not already set (first run ever)
    var ts_buf: [20]u8 = undefined;
    const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch "0";
    client.exec(
        "UPDATE stats SET service_started_at = ? WHERE id = 1 AND service_started_at IS NULL",
        &.{ts_str},
    ) catch {};

    // popular searches tracking
    try client.exec(
        \\CREATE TABLE IF NOT EXISTS popular_searches (
        \\  query TEXT PRIMARY KEY,
        \\  count INTEGER DEFAULT 1
        \\)
    , &.{});
}

fn runMigrations(client: *Client) !void {
    // these may fail if columns already exist - that's fine
    client.exec("ALTER TABLE documents ADD COLUMN publication_uri TEXT", &.{}) catch {};
    client.exec("ALTER TABLE publications ADD COLUMN base_path TEXT", &.{}) catch {};
    client.exec("ALTER TABLE stats ADD COLUMN service_started_at INTEGER", &.{}) catch {};
}
