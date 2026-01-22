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
        \\  description,
        \\  base_path
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

    // tombstones for deleted records
    try client.exec(
        \\CREATE TABLE IF NOT EXISTS tombstones (
        \\  uri TEXT PRIMARY KEY,
        \\  record_type TEXT NOT NULL,
        \\  deleted_at INTEGER NOT NULL
        \\)
    , &.{});

    // similarity cache: stores precomputed similar documents
    // invalidated when doc_count changes (new docs added/removed)
    try client.exec(
        \\CREATE TABLE IF NOT EXISTS similarity_cache (
        \\  source_uri TEXT PRIMARY KEY,
        \\  results TEXT NOT NULL,
        \\  doc_count INTEGER NOT NULL,
        \\  computed_at INTEGER NOT NULL
        \\)
    , &.{});
}

fn runMigrations(client: *Client) !void {
    // these may fail if columns already exist - that's fine
    client.exec("ALTER TABLE documents ADD COLUMN publication_uri TEXT", &.{}) catch {};
    client.exec("ALTER TABLE publications ADD COLUMN base_path TEXT", &.{}) catch {};
    client.exec("ALTER TABLE stats ADD COLUMN service_started_at INTEGER", &.{}) catch {};
    client.exec("ALTER TABLE stats ADD COLUMN cache_hits INTEGER DEFAULT 0", &.{}) catch {};
    client.exec("ALTER TABLE stats ADD COLUMN cache_misses INTEGER DEFAULT 0", &.{}) catch {};

    // multi-platform support: track source platform and collection
    client.exec("ALTER TABLE documents ADD COLUMN platform TEXT DEFAULT 'leaflet'", &.{}) catch {};
    client.exec("ALTER TABLE documents ADD COLUMN source_collection TEXT DEFAULT 'pub.leaflet.document'", &.{}) catch {};

    // backfill existing records (idempotent - only updates NULLs)
    client.exec("UPDATE documents SET platform = 'leaflet' WHERE platform IS NULL", &.{}) catch {};
    client.exec("UPDATE documents SET source_collection = 'pub.leaflet.document' WHERE source_collection IS NULL", &.{}) catch {};

    // multi-platform support for publications
    client.exec("ALTER TABLE publications ADD COLUMN platform TEXT DEFAULT 'leaflet'", &.{}) catch {};
    client.exec("ALTER TABLE publications ADD COLUMN source_collection TEXT DEFAULT 'pub.leaflet.publication'", &.{}) catch {};
    client.exec("UPDATE publications SET platform = 'leaflet' WHERE platform IS NULL", &.{}) catch {};
    client.exec("UPDATE publications SET source_collection = 'pub.leaflet.publication' WHERE source_collection IS NULL", &.{}) catch {};

    // vector embeddings column already added by backfill script

    // dedupe index: same (did, rkey) across collections = same document
    // e.g., pub.leaflet.document/abc and site.standard.document/abc are the same content
    client.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_documents_did_rkey ON documents(did, rkey)", &.{}) catch {};
    client.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_publications_did_rkey ON publications(did, rkey)", &.{}) catch {};

    // backfill platform from source_collection for records indexed before platform detection fix
    client.exec("UPDATE documents SET platform = 'leaflet' WHERE platform = 'unknown' AND source_collection LIKE 'pub.leaflet.%'", &.{}) catch {};
    client.exec("UPDATE documents SET platform = 'pckt' WHERE platform = 'unknown' AND source_collection LIKE 'blog.pckt.%'", &.{}) catch {};

    // detect platform from publication basePath (site.standard.* is a lexicon, not a platform)
    // pckt uses site.standard.* lexicon but basePath contains pckt.blog
    client.exec(
        \\UPDATE documents SET platform = 'pckt'
        \\WHERE platform IN ('standardsite', 'unknown')
        \\AND publication_uri IN (SELECT uri FROM publications WHERE base_path LIKE '%pckt.blog%')
    , &.{}) catch {};

    // leaflet also uses site.standard.* lexicon, detect by basePath
    client.exec(
        \\UPDATE documents SET platform = 'leaflet'
        \\WHERE platform IN ('standardsite', 'unknown')
        \\AND publication_uri IN (SELECT uri FROM publications WHERE base_path LIKE '%leaflet.pub%')
    , &.{}) catch {};

    // URL path field for documents (e.g., "/001" for zat.dev)
    // used to build full URL: publication.url + document.path
    client.exec("ALTER TABLE documents ADD COLUMN path TEXT", &.{}) catch {};

    // denormalized columns for query performance (avoids per-row subqueries)
    client.exec("ALTER TABLE documents ADD COLUMN base_path TEXT DEFAULT ''", &.{}) catch {};
    client.exec("ALTER TABLE documents ADD COLUMN has_publication INTEGER DEFAULT 0", &.{}) catch {};

    // backfill base_path from publications (idempotent - only updates empty values)
    client.exec(
        \\UPDATE documents SET base_path = COALESCE(
        \\  (SELECT p.base_path FROM publications p WHERE p.uri = documents.publication_uri),
        \\  (SELECT p.base_path FROM publications p WHERE p.did = documents.did LIMIT 1),
        \\  ''
        \\) WHERE base_path IS NULL OR base_path = ''
    , &.{}) catch {};

    // backfill has_publication (idempotent)
    client.exec(
        "UPDATE documents SET has_publication = CASE WHEN publication_uri != '' THEN 1 ELSE 0 END WHERE has_publication = 0 AND publication_uri != ''",
        &.{},
    ) catch {};

    // note: publications_fts was rebuilt with base_path column via scripts/rebuild-pub-fts
    // new publications will include base_path via insertPublication in indexer.zig
}
