const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const zql = @import("zql");
const logfire = @import("logfire");
const db = @import("../db.zig");
const tpuf = @import("../tpuf.zig");

pub const SearchMode = enum {
    keyword,
    semantic,
    hybrid,

    pub fn fromString(s: ?[]const u8) SearchMode {
        const str = s orelse return .keyword;
        if (std.mem.eql(u8, str, "semantic")) return .semantic;
        if (std.mem.eql(u8, str, "hybrid")) return .hybrid;
        return .keyword;
    }
};

// JSON output type for search results
const SearchResultJson = struct {
    type: []const u8,
    uri: []const u8,
    did: []const u8,
    title: []const u8,
    snippet: []const u8,
    createdAt: []const u8 = "",
    rkey: []const u8,
    basePath: []const u8,
    platform: []const u8,
    path: []const u8 = "", // URL path from record (e.g., "/001")
    source: []const u8 = "",
    coverImage: []const u8 = "",
    publicationName: []const u8 = "",
    url: []const u8 = "",
};

/// Document search result (internal)
const Doc = struct {
    uri: []const u8,
    did: []const u8,
    title: []const u8,
    snippet: []const u8,
    createdAt: []const u8,
    rkey: []const u8,
    basePath: []const u8,
    hasPublication: bool,
    platform: []const u8,
    path: []const u8,
    coverImage: []const u8,
    publicationName: []const u8,

    fn fromRow(row: db.Row) Doc {
        return .{
            .uri = row.text(docCol("uri")),
            .did = row.text(docCol("did")),
            .title = row.text(docCol("title")),
            .snippet = row.text(docCol("snippet")),
            .createdAt = row.text(docCol("created_at")),
            .rkey = row.text(docCol("rkey")),
            .basePath = row.text(docCol("base_path")),
            .hasPublication = row.int(docCol("has_publication")) != 0,
            .platform = row.text(docCol("platform")),
            .path = row.text(docCol("path")),
            .coverImage = row.text(docCol("cover_image")),
            .publicationName = row.text(docCol("publication_name")),
        };
    }

    fn fromLocalRow(row: db.LocalDb.Row) Doc {
        // local-side SQL strings (in searchLocal) share the same column
        // projection as the Turso doc queries — they have to, since Doc has
        // exactly one shape. Reusing docCol gives us the comptime-checked
        // index lookups for the local path too.
        return .{
            .uri = row.text(docCol("uri")),
            .did = row.text(docCol("did")),
            .title = row.text(docCol("title")),
            .snippet = row.text(docCol("snippet")),
            .createdAt = row.text(docCol("created_at")),
            .rkey = row.text(docCol("rkey")),
            .basePath = row.text(docCol("base_path")),
            .hasPublication = row.int(docCol("has_publication")) != 0,
            .platform = row.text(docCol("platform")),
            .path = row.text(docCol("path")),
            .coverImage = row.text(docCol("cover_image")),
            .publicationName = row.text(docCol("publication_name")),
        };
    }

    fn toJson(self: Doc, alloc: Allocator) SearchResultJson {
        const doc_type: []const u8 = if (self.hasPublication) "article" else "looseleaf";
        return .{
            .type = doc_type,
            .uri = self.uri,
            .did = self.did,
            .title = self.title,
            .snippet = self.snippet,
            .createdAt = self.createdAt,
            .rkey = self.rkey,
            .basePath = self.basePath,
            .platform = self.platform,
            .path = self.path,
            .coverImage = self.coverImage,
            .publicationName = self.publicationName,
            .url = buildDocUrl(alloc, doc_type, self.platform, self.basePath, self.path, self.rkey, self.did),
        };
    }
};

/// Build canonical URL for a document/publication from its fields.
/// Single source of truth: the frontend renders `doc.url` from this verbatim.
pub fn buildDocUrl(alloc: Allocator, doc_type: []const u8, platform: []const u8, base_path: []const u8, path: []const u8, rkey: []const u8, did: []const u8) []const u8 {
    // publication → https://{basePath}
    if (std.mem.eql(u8, doc_type, "publication") and base_path.len > 0) {
        return std.fmt.allocPrint(alloc, "https://{s}", .{base_path}) catch "";
    }
    // skip non-document-serving hosts (blento is a card portal, not a document platform)
    const usable_base = base_path.len > 0 and !std.mem.startsWith(u8, base_path, "blento.app");
    // explicit path wins → https://{basePath}[/]{path}
    // the rkey-URL form below is a leaflet.pub convention; it must NOT override an
    // author-set path. site.standard.document records embedding pub.leaflet.content
    // get tagged platform=leaflet (indexer.zig) but are served by their own path —
    // native pub.leaflet.document records never carry a path, so they fall through.
    if (usable_base and path.len > 0) {
        const sep: []const u8 = if (path[0] == '/') "" else "/";
        return std.fmt.allocPrint(alloc, "https://{s}{s}{s}", .{ base_path, sep, path }) catch "";
    }
    // leaflet + basePath + rkey → https://{basePath}/{rkey}
    if (std.mem.eql(u8, platform, "leaflet") and usable_base and rkey.len > 0) {
        return std.fmt.allocPrint(alloc, "https://{s}/{s}", .{ base_path, rkey }) catch "";
    }
    // leaflet fallback → https://leaflet.pub/p/{did}/{rkey}
    if (std.mem.eql(u8, platform, "leaflet") and did.len > 0 and rkey.len > 0) {
        return std.fmt.allocPrint(alloc, "https://leaflet.pub/p/{s}/{s}", .{ did, rkey }) catch "";
    }
    // whitewind fallback → https://whtwnd.com/{did}/{rkey}
    if (std.mem.eql(u8, platform, "whitewind") and did.len > 0 and rkey.len > 0) {
        return std.fmt.allocPrint(alloc, "https://whtwnd.com/{s}/{s}", .{ did, rkey }) catch "";
    }
    // universal fallback → AT Protocol record viewer
    if (did.len > 0 and rkey.len > 0) {
        return std.fmt.allocPrint(alloc, "https://pdsls.dev/at/{s}/site.standard.document/{s}", .{ did, rkey }) catch "";
    }
    return "";
}

const DocsByTag = zql.Query(
    \\SELECT d.uri, d.did, d.title, '' as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image,
    \\  COALESCE(p.name, '') as publication_name
    \\FROM documents d
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\JOIN document_tags dt ON d.uri = dt.document_uri
    \\WHERE dt.tag = :tag
    \\ORDER BY d.created_at DESC LIMIT 40
);

const DocsByFtsAndTag = zql.Query(
    \\SELECT f.uri, d.did, d.title,
    \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image,
    \\  COALESCE(p.name, '') as publication_name
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\JOIN document_tags dt ON d.uri = dt.document_uri
    \\WHERE documents_fts MATCH :query AND dt.tag = :tag
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

const DocsByFts = zql.Query(
    \\SELECT f.uri, d.did, d.title,
    \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image,
    \\  COALESCE(p.name, '') as publication_name
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\WHERE documents_fts MATCH :query
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

const DocsByFtsAndSince = zql.Query(
    \\SELECT f.uri, d.did, d.title,
    \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image,
    \\  COALESCE(p.name, '') as publication_name
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\WHERE documents_fts MATCH :query AND d.created_at >= :since
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

const DocsByFtsAndPlatform = zql.Query(
    \\SELECT f.uri, d.did, d.title,
    \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image,
    \\  COALESCE(p.name, '') as publication_name
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\WHERE documents_fts MATCH :query AND d.platform = :platform
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

const DocsByFtsAndPlatformAndSince = zql.Query(
    \\SELECT f.uri, d.did, d.title,
    \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image,
    \\  COALESCE(p.name, '') as publication_name
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\WHERE documents_fts MATCH :query AND d.platform = :platform AND d.created_at >= :since
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

const DocsByTagAndPlatform = zql.Query(
    \\SELECT d.uri, d.did, d.title, '' as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image,
    \\  COALESCE(p.name, '') as publication_name
    \\FROM documents d
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\JOIN document_tags dt ON d.uri = dt.document_uri
    \\WHERE dt.tag = :tag AND d.platform = :platform
    \\ORDER BY d.created_at DESC LIMIT 40
);

const DocsByFtsAndTagAndPlatform = zql.Query(
    \\SELECT f.uri, d.did, d.title,
    \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image,
    \\  COALESCE(p.name, '') as publication_name
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\JOIN document_tags dt ON d.uri = dt.document_uri
    \\WHERE documents_fts MATCH :query AND dt.tag = :tag AND d.platform = :platform
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

const DocsByPlatform = zql.Query(
    \\SELECT d.uri, d.did, d.title, '' as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image,
    \\  COALESCE(p.name, '') as publication_name
    \\FROM documents d
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\WHERE d.platform = :platform
    \\ORDER BY d.created_at DESC LIMIT 40
);

const DocsByAuthor = zql.Query(
    \\SELECT d.uri, d.did, d.title, '' as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image,
    \\  COALESCE(p.name, '') as publication_name
    \\FROM documents d
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\WHERE d.did = :author AND (d.is_bridgyfed IS NULL OR d.is_bridgyfed = 0) AND (d.url_dead IS NULL OR d.url_dead = 0)
    \\ORDER BY d.created_at DESC LIMIT 40
);

const DocsByAuthorAndPlatform = zql.Query(
    \\SELECT d.uri, d.did, d.title, '' as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image,
    \\  COALESCE(p.name, '') as publication_name
    \\FROM documents d
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\WHERE d.did = :author AND d.platform = :platform AND (d.is_bridgyfed IS NULL OR d.is_bridgyfed = 0) AND (d.url_dead IS NULL OR d.url_dead = 0)
    \\ORDER BY d.created_at DESC LIMIT 40
);

// Find documents by their publication's base_path (subdomain search)
// e.g., searching "gyst" finds all docs on gyst.leaflet.pub
// Uses recency decay: recent docs rank higher than old ones with same match
const DocsByPubBasePath = zql.Query(
    \\SELECT d.uri, d.did, d.title, '' as snippet,
    \\  d.created_at, d.rkey,
    \\  p.base_path,
    \\  1 as has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image,
    \\  COALESCE(p.name, '') as publication_name
    \\FROM documents d
    \\JOIN publications p ON d.publication_uri = p.uri
    \\JOIN publications_fts pf ON p.uri = pf.uri
    \\WHERE publications_fts MATCH :query
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

const DocsByPubBasePathAndPlatform = zql.Query(
    \\SELECT d.uri, d.did, d.title, '' as snippet,
    \\  d.created_at, d.rkey,
    \\  p.base_path,
    \\  1 as has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image,
    \\  COALESCE(p.name, '') as publication_name
    \\FROM documents d
    \\JOIN publications p ON d.publication_uri = p.uri
    \\JOIN publications_fts pf ON p.uri = pf.uri
    \\WHERE publications_fts MATCH :query AND d.platform = :platform
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

const DocsByPubBasePathAndSince = zql.Query(
    \\SELECT d.uri, d.did, d.title, '' as snippet,
    \\  d.created_at, d.rkey,
    \\  p.base_path,
    \\  1 as has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image,
    \\  COALESCE(p.name, '') as publication_name
    \\FROM documents d
    \\JOIN publications p ON d.publication_uri = p.uri
    \\JOIN publications_fts pf ON p.uri = pf.uri
    \\WHERE publications_fts MATCH :query AND d.created_at >= :since
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

const DocsByPubBasePathAndPlatformAndSince = zql.Query(
    \\SELECT d.uri, d.did, d.title, '' as snippet,
    \\  d.created_at, d.rkey,
    \\  p.base_path,
    \\  1 as has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image,
    \\  COALESCE(p.name, '') as publication_name
    \\FROM documents d
    \\JOIN publications p ON d.publication_uri = p.uri
    \\JOIN publications_fts pf ON p.uri = pf.uri
    \\WHERE publications_fts MATCH :query AND d.platform = :platform AND d.created_at >= :since
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

// Every doc query above shares the same column projection. Picking one as
// the canonical column-index source lets Doc.fromRow look up by name
// instead of positional index — adding/removing/reordering columns is a
// compile error rather than a silent runtime miscount. The comptime
// assertion below catches the case where one of the queries drifts from
// the rest.
const DocQueries = .{
    DocsByTag,                            DocsByFtsAndTag,
    DocsByFts,                            DocsByFtsAndSince,
    DocsByFtsAndPlatform,                 DocsByFtsAndPlatformAndSince,
    DocsByTagAndPlatform,                 DocsByFtsAndTagAndPlatform,
    DocsByPlatform,                       DocsByAuthor,
    DocsByAuthorAndPlatform,              DocsByPubBasePath,
    DocsByPubBasePathAndPlatform,         DocsByPubBasePathAndSince,
    DocsByPubBasePathAndPlatformAndSince,
};

inline fn docCol(comptime name: []const u8) comptime_int {
    @setEvalBranchQuota(20000);
    const canonical = DocsByTag.columnIndex(name);
    inline for (DocQueries) |Q| {
        if (Q.columnIndex(name) != canonical) {
            @compileError("doc query column index drift for '" ++ name ++ "'");
        }
    }
    return canonical;
}

// Publication-side equivalent. Only one Pub query (PubSearch) today, so the
// helper just defers to its columnIndex; if we add more Pub query variants
// later, mirror the docCol drift-check pattern.
inline fn pubCol(comptime name: []const u8) comptime_int {
    return PubSearch.columnIndex(name);
}

/// Publication search result (internal)
const Pub = struct {
    uri: []const u8,
    did: []const u8,
    name: []const u8,
    snippet: []const u8,
    rkey: []const u8,
    basePath: []const u8,
    platform: []const u8,

    fn fromRow(row: db.Row) Pub {
        return .{
            .uri = row.text(pubCol("uri")),
            .did = row.text(pubCol("did")),
            .name = row.text(pubCol("name")),
            .snippet = row.text(pubCol("snippet")),
            .rkey = row.text(pubCol("rkey")),
            .basePath = row.text(pubCol("base_path")),
            .platform = row.text(pubCol("platform")),
        };
    }

    fn fromLocalRow(row: db.LocalDb.Row) Pub {
        // local-side pub SQL (in searchLocal) mirrors PubSearch's projection.
        return .{
            .uri = row.text(pubCol("uri")),
            .did = row.text(pubCol("did")),
            .name = row.text(pubCol("name")),
            .snippet = row.text(pubCol("snippet")),
            .rkey = row.text(pubCol("rkey")),
            .basePath = row.text(pubCol("base_path")),
            .platform = row.text(pubCol("platform")),
        };
    }

    fn toJson(self: Pub, alloc: Allocator) SearchResultJson {
        return .{
            .type = "publication",
            .uri = self.uri,
            .did = self.did,
            .title = self.name,
            .snippet = self.snippet,
            .rkey = self.rkey,
            .basePath = self.basePath,
            .platform = self.platform,
            .url = buildDocUrl(alloc, "publication", self.platform, self.basePath, "", self.rkey, self.did),
        };
    }
};

const PubSearch = zql.Query(
    \\SELECT f.uri, p.did, p.name,
    \\  snippet(publications_fts, 2, '', '', '...', 32) as snippet,
    \\  p.rkey, p.base_path, p.platform
    \\FROM publications_fts f
    \\JOIN publications p ON f.uri = p.uri
    \\WHERE publications_fts MATCH :query
    \\ORDER BY rank + (julianday('now') - julianday(p.created_at)) / 30.0 LIMIT 10
);

pub fn search(alloc: Allocator, query: []const u8, tag_filter: ?[]const u8, platform_filter: ?[]const u8, since_filter: ?[]const u8, author_filter: ?[]const u8, mode: SearchMode) ![]const u8 {
    if (mode == .hybrid) return searchHybrid(alloc, query, tag_filter, platform_filter, since_filter, author_filter);
    if (mode == .semantic) return searchSemantic(alloc, query, platform_filter, since_filter, author_filter);
    return searchKeyword(alloc, query, tag_filter, platform_filter, since_filter, author_filter);
}

/// Whether a doc's `created_at` satisfies an active `since` lower bound.
/// No filter → always passes. Empty created_at fails when a filter is active
/// (an unknown date can't be proven in-range — previously these leaked through).
/// Lexicographic compare is valid because both are ISO-8601: `created_at` is a
/// full timestamp, `since` a date prefix, so "2026-05-29T..." >= "2026-05-29".
fn passesSince(created_at: []const u8, since_filter: ?[]const u8) bool {
    const since = since_filter orelse return true;
    if (created_at.len == 0) return false;
    return std.mem.order(u8, created_at, since) != .lt;
}

test "passesSince" {
    // no active filter: everything passes, including empty dates
    try std.testing.expect(passesSince("", null));
    try std.testing.expect(passesSince("2020-01-01T00:00:00Z", null));

    const since: ?[]const u8 = "2026-05-29";
    try std.testing.expect(passesSince("2026-06-02T18:23:34.663Z", since)); // newer
    try std.testing.expect(passesSince("2026-05-29T00:00:00Z", since)); // same day, kept
    try std.testing.expect(!passesSince("2026-05-28T23:59:59Z", since)); // older, dropped
    try std.testing.expect(!passesSince("2025-04-05T18:15:48.435Z", since)); // much older
    try std.testing.expect(!passesSince("", since)); // unknown date dropped under filter
}

/// Check if we've already seen a result from the same author with the same title.
/// Used to collapse cross-platform duplicates (same content published to multiple ATProto apps).
fn isDuplicateAuthorTitle(seen: *std.StringHashMap(void), alloc: Allocator, did: []const u8, title: []const u8) !bool {
    if (did.len == 0 or title.len == 0) return false;
    const key = try std.fmt.allocPrint(alloc, "{s}\x00{s}", .{ did, title });
    const result = try seen.getOrPut(key);
    if (result.found_existing) {
        alloc.free(key);
        return true;
    }
    return false;
}

/// Inject an author DID condition into a SQL query's WHERE clause before ORDER BY.
/// Uses the (? = '' OR col = ?) pattern: no-op when author_val is empty.
fn addAuthorCondition(alloc: Allocator, stmt: db.Client.Statement, col: []const u8, author_val: []const u8) !db.Client.Statement {
    const order_idx = std.mem.indexOf(u8, stmt.sql, "ORDER BY") orelse return stmt;
    const new_sql = try std.fmt.allocPrint(alloc, "{s}AND (? = '' OR {s} = ?) {s}", .{ stmt.sql[0..order_idx], col, stmt.sql[order_idx..] });
    const new_args = try alloc.alloc([]const u8, stmt.args.len + 2);
    @memcpy(new_args[0..stmt.args.len], stmt.args);
    new_args[stmt.args.len] = author_val;
    new_args[stmt.args.len + 1] = author_val;
    return .{ .sql = new_sql, .args = new_args };
}

/// Inject bridgy fed exclusion into a SQL query's WHERE clause before ORDER BY.
/// Excludes documents where is_bridgyfed = 1 (bridgy fed content).
fn addBridgyFedExclusion(alloc: Allocator, stmt: db.Client.Statement) !db.Client.Statement {
    const order_idx = std.mem.indexOf(u8, stmt.sql, "ORDER BY") orelse return stmt;
    const new_sql = try std.fmt.allocPrint(alloc, "{s}AND (d.is_bridgyfed IS NULL OR d.is_bridgyfed = 0) AND (d.url_dead IS NULL OR d.url_dead = 0) {s}", .{ stmt.sql[0..order_idx], stmt.sql[order_idx..] });
    return .{ .sql = new_sql, .args = stmt.args };
}

/// Check if a URI is from bridgy fed by looking up is_bridgyfed in local SQLite.
fn isBridgyFed(uri: []const u8) bool {
    const local = db.getLocalDb() orelse return false;
    var rows = local.query(
        "SELECT is_bridgyfed FROM documents WHERE uri = ?",
        .{uri},
    ) catch return false;
    defer rows.deinit();
    if (rows.next()) |row| {
        return row.int(0) != 0;
    }
    return false;
}

/// Keyword search: FTS5 via local SQLite or Turso fallback.
fn searchKeyword(alloc: Allocator, query: []const u8, tag_filter: ?[]const u8, platform_filter: ?[]const u8, since_filter: ?[]const u8, author_filter: ?[]const u8) ![]const u8 {
    // try local SQLite first (faster for FTS queries)
    if (db.getLocalDb()) |local| {
        if (searchLocal(alloc, local, query, tag_filter, platform_filter, since_filter, author_filter)) |result| {
            logfire.info("search.local hit", .{});
            return result;
        } else |err| {
            logfire.warn("search.local failed, falling back to turso: {s}", .{@errorName(err)});
        }
    } else {
        logfire.warn("search.local unavailable (not ready), falling back to turso", .{});
    }

    // fall back to Turso
    logfire.info("search.turso fallback", .{});
    const c = db.getClient() orelse return error.NotInitialized;

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();

    const fts_query = try buildFtsQuery(alloc, query);
    const has_query = query.len > 0;
    const has_tag = tag_filter != null;
    const has_platform = platform_filter != null;
    const has_since = since_filter != null;

    // track seen URIs for deduplication (content match + base_path match)
    var seen_uris = std.StringHashMap(void).init(alloc);
    defer seen_uris.deinit();

    // track seen (did, title) pairs for cross-platform dedup
    var seen_authors = std.StringHashMap(void).init(alloc);
    defer seen_authors.deinit();

    // author-only browse: no FTS query needed, just fetch by DID
    if (author_filter != null and !has_query and !has_tag) {
        if (has_platform) {
            var res = c.query(DocsByAuthorAndPlatform.positional, &.{ author_filter.?, platform_filter.? }) catch {
                try jw.endArray();
                return try output.toOwnedSlice();
            };
            defer res.deinit();
            for (res.rows) |row| {
                const doc = Doc.fromRow(row);
                if (try isDuplicateAuthorTitle(&seen_authors, alloc, doc.did, doc.title)) continue;
                try jw.write(doc.toJson(alloc));
            }
        } else {
            var res = c.query(DocsByAuthor.positional, &.{author_filter.?}) catch {
                try jw.endArray();
                return try output.toOwnedSlice();
            };
            defer res.deinit();
            for (res.rows) |row| {
                const doc = Doc.fromRow(row);
                if (try isDuplicateAuthorTitle(&seen_authors, alloc, doc.did, doc.title)) continue;
                try jw.write(doc.toJson(alloc));
            }
        }
        try jw.endArray();
        return try output.toOwnedSlice();
    }

    // build batch of queries to execute in single HTTP request
    var statements: [3]db.Client.Statement = undefined;
    var stmt_count: usize = 0;

    // author condition: inject into SQL so LIMIT applies after author filtering
    const author_val: []const u8 = if (author_filter) |af| af else "";

    // query 0: documents by content (always present if we have any filter)
    const doc_sql = getDocQuerySql(has_query, has_tag, has_platform, has_since);
    const doc_args = try getDocQueryArgs(alloc, fts_query, tag_filter, platform_filter, since_filter, has_query, has_tag, has_platform, has_since);
    if (doc_sql) |sql| {
        statements[stmt_count] = try addBridgyFedExclusion(alloc, try addAuthorCondition(alloc, .{ .sql = sql, .args = doc_args }, "d.did", author_val));
        stmt_count += 1;
    }

    // query 1: documents by publication base_path (subdomain search)
    const run_basepath = has_query and !has_tag;
    if (run_basepath) {
        var base_stmt: db.Client.Statement = undefined;
        if (has_platform and has_since) {
            base_stmt = .{ .sql = DocsByPubBasePathAndPlatformAndSince.positional, .args = &.{ fts_query, platform_filter.?, since_filter.? } };
        } else if (has_platform) {
            base_stmt = .{ .sql = DocsByPubBasePathAndPlatform.positional, .args = &.{ fts_query, platform_filter.? } };
        } else if (has_since) {
            base_stmt = .{ .sql = DocsByPubBasePathAndSince.positional, .args = &.{ fts_query, since_filter.? } };
        } else {
            base_stmt = .{ .sql = DocsByPubBasePath.positional, .args = &.{fts_query} };
        }
        statements[stmt_count] = try addBridgyFedExclusion(alloc, try addAuthorCondition(alloc, base_stmt, "d.did", author_val));
        stmt_count += 1;
    }

    // query 2: publications (only when no tag/platform filter)
    // Publications carry no post-date (the local replica omits created_at), so
    // they can't honor a date bound. Under an active date filter, suppress them
    // rather than leaking undated publication shells into a recency-bounded view.
    const run_pubs = tag_filter == null and platform_filter == null and has_query and !has_since;
    if (run_pubs) {
        statements[stmt_count] = try addAuthorCondition(alloc, .{ .sql = PubSearch.positional, .args = &.{fts_query} }, "p.did", author_val);
        stmt_count += 1;
    }

    if (stmt_count == 0) {
        try jw.endArray();
        return try output.toOwnedSlice();
    }

    // execute all queries in single HTTP request
    var batch = c.queryBatch(statements[0..stmt_count]) catch {
        try jw.endArray();
        return try output.toOwnedSlice();
    };
    defer batch.deinit();

    // process query 0: document content results
    var query_idx: usize = 0;
    if (doc_sql != null) {
        for (batch.get(query_idx)) |row| {
            const doc = Doc.fromRow(row);
            if (author_filter) |af| {
                if (!std.mem.eql(u8, doc.did, af)) continue;
            }
            if (try isDuplicateAuthorTitle(&seen_authors, alloc, doc.did, doc.title)) continue;
            const uri_dupe = try alloc.dupe(u8, doc.uri);
            try seen_uris.put(uri_dupe, {});
            try jw.write(doc.toJson(alloc));
        }
        query_idx += 1;
    }

    // process query 1: base_path results (deduplicated)
    if (run_basepath) {
        for (batch.get(query_idx)) |row| {
            const doc = Doc.fromRow(row);
            if (author_filter) |af| {
                if (!std.mem.eql(u8, doc.did, af)) continue;
            }
            if (!seen_uris.contains(doc.uri) and !try isDuplicateAuthorTitle(&seen_authors, alloc, doc.did, doc.title)) {
                try jw.write(doc.toJson(alloc));
            }
        }
        query_idx += 1;
    }

    // process query 2: publication results
    if (run_pubs) {
        for (batch.get(query_idx)) |row| {
            const pub_result = Pub.fromRow(row);
            if (author_filter) |af| {
                if (!std.mem.eql(u8, pub_result.did, af)) continue;
            }
            try jw.write(pub_result.toJson(alloc));
        }
    }

    try jw.endArray();
    return try output.toOwnedSlice();
}

/// Local SQLite search (FTS queries only, no vector similarity)
/// Simplified version - just handles basic FTS query case to get started
fn searchLocal(alloc: Allocator, local: *db.LocalDb, query: []const u8, tag_filter: ?[]const u8, platform_filter: ?[]const u8, since_filter: ?[]const u8, author_filter: ?[]const u8) ![]const u8 {
    // only handle basic FTS queries for now (most common case)
    // fall back to Turso for complex filter combinations and author-only browse
    if (query.len == 0 or tag_filter != null) {
        return error.UnsupportedQuery;
    }

    // author condition: pass DID or "" (empty = no-op via SQL "? = '' OR d.did = ?")
    const author_val: []const u8 = if (author_filter) |af| af else "";

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();

    const fts_query = try buildFtsQuery(alloc, query);

    // track seen URIs for deduplication
    var seen_uris = std.StringHashMap(void).init(alloc);
    defer seen_uris.deinit();

    // track seen (did, title) pairs for cross-platform dedup
    var seen_authors = std.StringHashMap(void).init(alloc);
    defer seen_authors.deinit();

    // document content search
    if (platform_filter) |platform| {
        var rows = try local.query(
            \\SELECT f.uri, d.did, d.title,
            \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
            \\  d.created_at, d.rkey, d.base_path, d.has_publication,
            \\  d.platform, COALESCE(d.path, '') as path,
            \\  COALESCE(d.cover_image, '') as cover_image,
            \\  COALESCE(p.name, '') as publication_name
            \\FROM documents_fts f
            \\JOIN documents d ON f.uri = d.uri
            \\LEFT JOIN publications p ON d.publication_uri = p.uri
            \\WHERE documents_fts MATCH ? AND d.platform = ? AND (? = '' OR d.did = ?)
            \\AND (d.is_bridgyfed IS NULL OR d.is_bridgyfed = 0) AND (d.url_dead IS NULL OR d.url_dead = 0)
            \\ORDER BY rank LIMIT 40
        , .{ fts_query, platform, author_val, author_val });
        defer rows.deinit();

        while (rows.next()) |row| {
            const doc = Doc.fromLocalRow(row);
            if (author_filter) |af| {
                if (!std.mem.eql(u8, doc.did, af)) continue;
            }
            if (!passesSince(doc.createdAt, since_filter)) continue;
            if (try isDuplicateAuthorTitle(&seen_authors, alloc, doc.did, doc.title)) continue;
            const uri_dupe = try alloc.dupe(u8, doc.uri);
            try seen_uris.put(uri_dupe, {});
            try jw.write(doc.toJson(alloc));
        }

        // base_path search with platform
        var bp_rows = try local.query(
            \\SELECT d.uri, d.did, d.title, '' as snippet,
            \\  d.created_at, d.rkey, p.base_path,
            \\  1 as has_publication, d.platform, COALESCE(d.path, '') as path,
            \\  COALESCE(d.cover_image, '') as cover_image,
            \\  COALESCE(p.name, '') as publication_name
            \\FROM documents d
            \\JOIN publications p ON d.publication_uri = p.uri
            \\JOIN publications_fts pf ON p.uri = pf.uri
            \\WHERE publications_fts MATCH ? AND d.platform = ? AND (? = '' OR d.did = ?)
            \\AND (d.is_bridgyfed IS NULL OR d.is_bridgyfed = 0) AND (d.url_dead IS NULL OR d.url_dead = 0)
            \\ORDER BY rank LIMIT 40
        , .{ fts_query, platform, author_val, author_val });
        defer bp_rows.deinit();

        while (bp_rows.next()) |row| {
            const doc = Doc.fromLocalRow(row);
            if (author_filter) |af| {
                if (!std.mem.eql(u8, doc.did, af)) continue;
            }
            if (!passesSince(doc.createdAt, since_filter)) continue;
            if (!seen_uris.contains(doc.uri) and !try isDuplicateAuthorTitle(&seen_authors, alloc, doc.did, doc.title)) {
                try jw.write(doc.toJson(alloc));
            }
        }
    } else {
        // no platform filter
        var rows = try local.query(
            \\SELECT f.uri, d.did, d.title,
            \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
            \\  d.created_at, d.rkey, d.base_path, d.has_publication,
            \\  d.platform, COALESCE(d.path, '') as path,
            \\  COALESCE(d.cover_image, '') as cover_image,
            \\  COALESCE(p.name, '') as publication_name
            \\FROM documents_fts f
            \\JOIN documents d ON f.uri = d.uri
            \\LEFT JOIN publications p ON d.publication_uri = p.uri
            \\WHERE documents_fts MATCH ? AND (? = '' OR d.did = ?)
            \\AND (d.is_bridgyfed IS NULL OR d.is_bridgyfed = 0) AND (d.url_dead IS NULL OR d.url_dead = 0)
            \\ORDER BY rank LIMIT 40
        , .{ fts_query, author_val, author_val });
        defer rows.deinit();

        {
            const iter_span = logfire.span("search.iterate.docs_fts", .{});
            defer iter_span.end();
            var doc_count: u32 = 0;
            while (rows.next()) |row| {
                const doc = Doc.fromLocalRow(row);
                if (author_filter) |af| {
                    if (!std.mem.eql(u8, doc.did, af)) continue;
                }
                if (!passesSince(doc.createdAt, since_filter)) continue;
                if (try isDuplicateAuthorTitle(&seen_authors, alloc, doc.did, doc.title)) continue;
                const uri_dupe = try alloc.dupe(u8, doc.uri);
                try seen_uris.put(uri_dupe, {});
                try jw.write(doc.toJson(alloc));
                doc_count += 1;
            }
            logfire.info("search.iterate.docs_fts rows={d}", .{doc_count});
        }

        // base_path search
        var bp_rows = try local.query(
            \\SELECT d.uri, d.did, d.title, '' as snippet,
            \\  d.created_at, d.rkey, p.base_path,
            \\  1 as has_publication, d.platform, COALESCE(d.path, '') as path,
            \\  COALESCE(d.cover_image, '') as cover_image,
            \\  COALESCE(p.name, '') as publication_name
            \\FROM documents d
            \\JOIN publications p ON d.publication_uri = p.uri
            \\JOIN publications_fts pf ON p.uri = pf.uri
            \\WHERE publications_fts MATCH ? AND (? = '' OR d.did = ?)
            \\AND (d.is_bridgyfed IS NULL OR d.is_bridgyfed = 0) AND (d.url_dead IS NULL OR d.url_dead = 0)
            \\ORDER BY rank LIMIT 40
        , .{ fts_query, author_val, author_val });
        defer bp_rows.deinit();

        {
            const iter_span = logfire.span("search.iterate.base_path", .{});
            defer iter_span.end();
            var bp_count: u32 = 0;
            while (bp_rows.next()) |row| {
                const doc = Doc.fromLocalRow(row);
                if (author_filter) |af| {
                    if (!std.mem.eql(u8, doc.did, af)) {
                        bp_count += 1;
                        continue;
                    }
                }
                if (!passesSince(doc.createdAt, since_filter)) {
                    bp_count += 1;
                    continue;
                }
                if (!seen_uris.contains(doc.uri) and !try isDuplicateAuthorTitle(&seen_authors, alloc, doc.did, doc.title)) {
                    try jw.write(doc.toJson(alloc));
                }
                bp_count += 1;
            }
            logfire.info("search.iterate.base_path rows={d}", .{bp_count});
        }

        // publication search — publications have no post-date (the local
        // replica omits created_at), so skip them under an active date filter
        // rather than leak undated publication shells into a recency view.
        if (since_filter == null) {
            var pub_rows = try local.query(
                \\SELECT f.uri, p.did, p.name,
                \\  snippet(publications_fts, 2, '', '', '...', 32) as snippet,
                \\  p.rkey, p.base_path, p.platform
                \\FROM publications_fts f
                \\JOIN publications p ON f.uri = p.uri
                \\WHERE publications_fts MATCH ? AND (? = '' OR p.did = ?)
                \\ORDER BY rank LIMIT 10
            , .{ fts_query, author_val, author_val });
            defer pub_rows.deinit();

            const iter_span = logfire.span("search.iterate.pubs_fts", .{});
            defer iter_span.end();
            var pub_count: u32 = 0;
            while (pub_rows.next()) |row| {
                const pub_result = Pub.fromLocalRow(row);
                if (author_filter) |af| {
                    if (!std.mem.eql(u8, pub_result.did, af)) {
                        pub_count += 1;
                        continue;
                    }
                }
                try jw.write(pub_result.toJson(alloc));
                pub_count += 1;
            }
            logfire.info("search.iterate.pubs_fts rows={d}", .{pub_count});
        }
    }

    try jw.endArray();
    return try output.toOwnedSlice();
}

fn getDocQuerySql(has_query: bool, has_tag: bool, has_platform: bool, has_since: bool) ?[]const u8 {
    if (has_query and has_tag and has_platform) return DocsByFtsAndTagAndPlatform.positional;
    if (has_query and has_tag) return DocsByFtsAndTag.positional;
    if (has_query and has_platform and has_since) return DocsByFtsAndPlatformAndSince.positional;
    if (has_query and has_platform) return DocsByFtsAndPlatform.positional;
    if (has_query and has_since) return DocsByFtsAndSince.positional;
    if (has_query) return DocsByFts.positional;
    if (has_tag and has_platform) return DocsByTagAndPlatform.positional;
    if (has_tag) return DocsByTag.positional;
    if (has_platform) return DocsByPlatform.positional;
    return null;
}

fn getDocQueryArgs(alloc: Allocator, fts_query: []const u8, tag: ?[]const u8, platform: ?[]const u8, since: ?[]const u8, has_query: bool, has_tag: bool, has_platform: bool, has_since: bool) ![]const []const u8 {
    if (has_query and has_tag and has_platform) {
        const args = try alloc.alloc([]const u8, 3);
        args[0] = fts_query;
        args[1] = tag.?;
        args[2] = platform.?;
        return args;
    }
    if (has_query and has_tag) {
        const args = try alloc.alloc([]const u8, 2);
        args[0] = fts_query;
        args[1] = tag.?;
        return args;
    }
    if (has_query and has_platform and has_since) {
        const args = try alloc.alloc([]const u8, 3);
        args[0] = fts_query;
        args[1] = platform.?;
        args[2] = since.?;
        return args;
    }
    if (has_query and has_platform) {
        const args = try alloc.alloc([]const u8, 2);
        args[0] = fts_query;
        args[1] = platform.?;
        return args;
    }
    if (has_query and has_since) {
        const args = try alloc.alloc([]const u8, 2);
        args[0] = fts_query;
        args[1] = since.?;
        return args;
    }
    if (has_query) {
        const args = try alloc.alloc([]const u8, 1);
        args[0] = fts_query;
        return args;
    }
    if (has_tag and has_platform) {
        const args = try alloc.alloc([]const u8, 2);
        args[0] = tag.?;
        args[1] = platform.?;
        return args;
    }
    if (has_tag) {
        const args = try alloc.alloc([]const u8, 1);
        args[0] = tag.?;
        return args;
    }
    if (has_platform) {
        const args = try alloc.alloc([]const u8, 1);
        args[0] = platform.?;
        return args;
    }
    return &.{};
}

/// Find documents similar to a given document via turbopuffer ANN search.
/// 1. Fetch source doc's vector from tpuf (~50ms)
/// 2. ANN nearest-neighbor query (~50ms)
/// 3. Filter out source URI, serialize results
pub fn findSimilar(alloc: Allocator, uri: []const u8, limit: usize) ![]const u8 {
    // hash URI to tpuf ID format (AT-URIs exceed tpuf's 64-byte limit)
    const hashed = tpuf.hashId(uri);

    // get source document's vector
    const vector = tpuf.getVectorById(alloc, &hashed) catch |err| {
        logfire.warn("similar: getVectorById failed for {s}: {}", .{ uri, err });
        return error.VectorNotFound;
    };
    defer alloc.free(vector);

    // ANN query (request limit+1 so we can filter out the source doc)
    const results = tpuf.query(alloc, vector, limit + 1) catch |err| {
        logfire.warn("similar: tpuf query failed: {}", .{err});
        return error.QueryFailed;
    };
    defer {
        for (results) |r| {
            alloc.free(r.id);
            alloc.free(r.uri);
            alloc.free(r.title);
            alloc.free(r.did);
            alloc.free(r.created_at);
            alloc.free(r.rkey);
            alloc.free(r.base_path);
            alloc.free(r.platform);
            alloc.free(r.path);
        }
        alloc.free(results);
    }

    // collect filtered URIs for snippet lookup
    var uri_buf: [21][]const u8 = undefined; // limit+1
    var uri_count: usize = 0;
    for (results) |r| {
        if (std.mem.eql(u8, r.uri, uri)) continue;
        if (uri_count >= limit) break;
        uri_buf[uri_count] = r.uri;
        uri_count += 1;
    }

    const extras = fetchLocalExtras(alloc, uri_buf[0..uri_count]);

    // serialize, filtering out the source URI
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    // track seen (did, title) pairs for cross-platform dedup
    var seen_authors = std.StringHashMap(void).init(alloc);
    defer seen_authors.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    var count: usize = 0;
    for (results) |r| {
        if (std.mem.eql(u8, r.uri, uri)) continue;
        if (count >= limit) break;
        if (try isDuplicateAuthorTitle(&seen_authors, alloc, r.did, r.title)) continue;
        const doc_type: []const u8 = if (r.has_publication) "article" else "looseleaf";
        // prefer authoritative local-replica URL fields over stale tpuf attrs
        const platform = extras.platforms.get(r.uri) orelse r.platform;
        const base_path = extras.base_paths.get(r.uri) orelse r.base_path;
        const path = extras.paths.get(r.uri) orelse r.path;
        try jw.write(SearchResultJson{
            .type = doc_type,
            .uri = r.uri,
            .did = r.did,
            .title = r.title,
            .snippet = extras.snippets.get(r.uri) orelse "",
            .createdAt = r.created_at,
            .rkey = r.rkey,
            .basePath = base_path,
            .platform = platform,
            .path = path,
            .coverImage = extras.cover_images.get(r.uri) orelse "",
            .publicationName = extras.pub_names.get(r.uri) orelse "",
            .url = buildDocUrl(alloc, doc_type, platform, base_path, path, r.rkey, r.did),
        });
        count += 1;
    }
    try jw.endArray();

    return try output.toOwnedSlice();
}

/// Hybrid search: run keyword + semantic, merge with Reciprocal Rank Fusion.
/// score(doc) = 1/(k + rank_keyword) + 1/(k + rank_semantic), k=60
fn searchHybrid(alloc: Allocator, query: []const u8, tag_filter: ?[]const u8, platform_filter: ?[]const u8, since_filter: ?[]const u8, author_filter: ?[]const u8) ![]const u8 {
    if (query.len == 0) return try alloc.dupe(u8, "[]");

    const span = logfire.span("search.hybrid", .{});
    defer span.end();

    // 1. keyword search (~10ms via local SQLite)
    const kw_json = searchKeyword(alloc, query, tag_filter, platform_filter, since_filter, author_filter) catch |err| blk: {
        logfire.warn("search.hybrid: keyword failed: {}", .{err});
        break :blk try alloc.dupe(u8, "[]");
    };

    // 2. semantic search (~550ms via voyage + tpuf)
    const sem_json = searchSemantic(alloc, query, platform_filter, since_filter, author_filter) catch |err| blk: {
        logfire.warn("search.hybrid: semantic failed: {}", .{err});
        break :blk try alloc.dupe(u8, "[]");
    };

    // check if semantic returned an error object (starts with '{')
    const sem_is_error = sem_json.len > 0 and sem_json[0] == '{';

    // 3. parse both into json.Value arrays
    const kw_parsed = json.parseFromSlice(json.Value, alloc, kw_json, .{}) catch {
        // if keyword parse fails, just return semantic (or empty)
        if (sem_is_error) return try alloc.dupe(u8, "[]");
        return sem_json;
    };
    defer kw_parsed.deinit();

    const kw_items = switch (kw_parsed.value) {
        .array => |arr| arr.items,
        else => &[_]json.Value{},
    };

    var sem_items: []const json.Value = &.{};
    var sem_parsed_opt: ?json.Parsed(json.Value) = null;
    defer if (sem_parsed_opt) |*p| p.deinit();

    if (!sem_is_error) {
        if (json.parseFromSlice(json.Value, alloc, sem_json, .{}) catch null) |parsed| {
            sem_parsed_opt = parsed;
            sem_items = switch (parsed.value) {
                .array => |arr| arr.items,
                else => &[_]json.Value{},
            };
        }
    }

    // if one side is empty, return the other with source annotation
    if (kw_items.len == 0 and sem_items.len == 0) {
        return try alloc.dupe(u8, "[]");
    }

    // 4. build RRF score map
    const RRF_K: f64 = 60.0;

    // source bits: 1=keyword, 2=semantic
    var scores = std.StringHashMap(f64).init(alloc);
    defer scores.deinit();
    var source_bits = std.StringHashMap(u8).init(alloc);
    defer source_bits.deinit();

    // map URI -> json object from keyword results (preferred for snippets)
    var kw_objects = std.StringHashMap(json.ObjectMap).init(alloc);
    defer kw_objects.deinit();
    var sem_objects = std.StringHashMap(json.ObjectMap).init(alloc);
    defer sem_objects.deinit();

    for (kw_items, 0..) |item, i| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const uri = jsonStr(obj, "uri");
        if (uri.len == 0) continue;

        const rank: f64 = @floatFromInt(i + 1);
        const rrf_score = 1.0 / (RRF_K + rank);

        const prev = scores.get(uri) orelse 0.0;
        try scores.put(uri, prev + rrf_score);

        const prev_bits = source_bits.get(uri) orelse 0;
        try source_bits.put(uri, prev_bits | 0b01);

        if (!kw_objects.contains(uri)) {
            try kw_objects.put(uri, obj);
        }
    }

    for (sem_items, 0..) |item, i| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const uri = jsonStr(obj, "uri");
        if (uri.len == 0) continue;

        const rank: f64 = @floatFromInt(i + 1);
        const rrf_score = 1.0 / (RRF_K + rank);

        const prev = scores.get(uri) orelse 0.0;
        try scores.put(uri, prev + rrf_score);

        const prev_bits = source_bits.get(uri) orelse 0;
        try source_bits.put(uri, prev_bits | 0b10);

        if (!sem_objects.contains(uri)) {
            try sem_objects.put(uri, obj);
        }
    }

    // 5. collect and sort by RRF score
    const ScoredUri = struct {
        uri: []const u8,
        score: f64,
    };

    var scored: std.ArrayList(ScoredUri) = .empty;
    defer scored.deinit(alloc);

    var it = scores.iterator();
    while (it.next()) |entry| {
        try scored.append(alloc, .{ .uri = entry.key_ptr.*, .score = entry.value_ptr.* });
    }

    std.mem.sort(ScoredUri, scored.items, {}, struct {
        fn lessThan(_: void, a: ScoredUri, b: ScoredUri) bool {
            return a.score > b.score; // descending
        }
    }.lessThan);

    // 6. fetch content previews for semantic-only results (they have no FTS snippet)
    const limit = @min(scored.items.len, 20);
    var sem_uri_buf: [20][]const u8 = undefined;
    var sem_uri_count: usize = 0;
    for (scored.items[0..limit]) |entry| {
        const bits = source_bits.get(entry.uri) orelse 0;
        if (bits == 0b10) { // semantic-only
            const obj = sem_objects.get(entry.uri) orelse continue;
            const existing_snippet = jsonStr(obj, "snippet");
            if (existing_snippet.len == 0 and sem_uri_count < 20) {
                sem_uri_buf[sem_uri_count] = entry.uri;
                sem_uri_count += 1;
            }
        }
    }
    const hybrid_extras = fetchLocalExtras(alloc, sem_uri_buf[0..sem_uri_count]);

    // 7. serialize top 20 with source annotation
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();

    // track seen (did, title) pairs for cross-platform dedup
    var seen_authors = std.StringHashMap(void).init(alloc);
    defer seen_authors.deinit();

    for (scored.items[0..limit]) |entry| {
        const bits = source_bits.get(entry.uri) orelse 0;
        // prefer keyword version (has FTS snippet)
        const obj = kw_objects.get(entry.uri) orelse sem_objects.get(entry.uri) orelse continue;

        // cross-platform dedup: skip if same author+title already emitted
        if (try isDuplicateAuthorTitle(&seen_authors, alloc, jsonStr(obj, "did"), jsonStr(obj, "title"))) continue;

        const source_label: []const u8 = switch (bits) {
            0b01 => "keyword",
            0b10 => "semantic",
            0b11 => "keyword+semantic",
            else => "",
        };

        // for semantic-only results with empty snippet, use fetched preview
        const snippet = blk: {
            const existing = jsonStr(obj, "snippet");
            if (existing.len > 0) break :blk existing;
            if (bits == 0b10) {
                break :blk hybrid_extras.snippets.get(entry.uri) orelse "";
            }
            break :blk existing;
        };

        try jw.beginObject();
        // write all standard fields from the source object
        inline for (.{ "type", "uri", "did", "title" }) |field| {
            try jw.objectField(field);
            try jw.write(jsonStr(obj, field));
        }
        try jw.objectField("snippet");
        try jw.write(snippet);
        inline for (.{ "rkey", "basePath", "platform", "path" }) |field| {
            try jw.objectField(field);
            try jw.write(jsonStr(obj, field));
        }
        // for semantic-only results, cover image may need local DB fallback
        const cover = blk: {
            const existing = jsonStr(obj, "coverImage");
            if (existing.len > 0) break :blk existing;
            if (bits & 0b10 != 0) break :blk hybrid_extras.cover_images.get(entry.uri) orelse "";
            break :blk existing;
        };
        try jw.objectField("coverImage");
        try jw.write(cover);
        // for semantic-only results, pub name may need local DB fallback
        const pub_name = blk: {
            const existing = jsonStr(obj, "publicationName");
            if (existing.len > 0) break :blk existing;
            if (bits & 0b10 != 0) break :blk hybrid_extras.pub_names.get(entry.uri) orelse "";
            break :blk existing;
        };
        try jw.objectField("publicationName");
        try jw.write(pub_name);
        try jw.objectField("url");
        try jw.write(buildDocUrl(alloc, jsonStr(obj, "type"), jsonStr(obj, "platform"), jsonStr(obj, "basePath"), jsonStr(obj, "path"), jsonStr(obj, "rkey"), jsonStr(obj, "did")));
        try jw.objectField("createdAt");
        try jw.write(jsonStr(obj, "createdAt"));
        try jw.objectField("source");
        try jw.write(source_label);
        try jw.objectField("score");
        try jw.write(entry.score);
        try jw.endObject();
    }

    try jw.endArray();
    return try output.toOwnedSlice();
}

/// Semantic search: embed query via Voyage, ANN search via turbopuffer.
fn searchSemantic(alloc: Allocator, query: []const u8, platform_filter: ?[]const u8, since_filter: ?[]const u8, author_filter: ?[]const u8) ![]const u8 {
    if (query.len == 0) return try alloc.dupe(u8, "[]");

    if (!tpuf.isSemanticEnabled()) {
        return try alloc.dupe(u8, "{\"error\":\"semantic search not available\"}");
    }

    const span = logfire.span("search.semantic", .{});
    defer span.end();

    // embed query (input_type="query" for asymmetric search)
    const vector = tpuf.embedQuery(alloc, query) catch |err| {
        logfire.warn("search.semantic: embed failed: {}", .{err});
        return try alloc.dupe(u8, "{\"error\":\"embedding failed\"}");
    };
    defer alloc.free(vector);

    // ANN query — over-fetch to allow filtering
    const results = tpuf.query(alloc, vector, 40) catch |err| {
        logfire.warn("search.semantic: tpuf query failed: {}", .{err});
        return try alloc.dupe(u8, "{\"error\":\"vector search failed\"}");
    };
    defer {
        for (results) |r| {
            alloc.free(r.id);
            alloc.free(r.uri);
            alloc.free(r.title);
            alloc.free(r.did);
            alloc.free(r.created_at);
            alloc.free(r.rkey);
            alloc.free(r.base_path);
            alloc.free(r.platform);
            alloc.free(r.path);
        }
        alloc.free(results);
    }

    // first pass: filter and collect URIs for snippet lookup
    var filtered_indices: [20]usize = undefined;
    var filtered_count: usize = 0;
    var seen: [20][]const u8 = undefined;
    var seen_count: usize = 0;

    // track seen (did, title) pairs for cross-platform dedup
    var seen_authors = std.StringHashMap(void).init(alloc);
    defer seen_authors.deinit();

    for (results, 0..) |r, idx| {
        if (filtered_count >= 20) break;
        if (r.title.len == 0) continue;
        if (isBridgyFed(r.uri)) continue;
        if (platform_filter) |pf| {
            if (!std.mem.eql(u8, r.platform, pf)) continue;
        }
        if (author_filter) |af| {
            if (!std.mem.eql(u8, r.did, af)) continue;
        }
        // date filter: tpuf has no since predicate, so apply it here (the
        // keyword path filters in SQL / via passesSince — semantic must match).
        if (!passesSince(r.created_at, since_filter)) continue;
        var is_dup = false;
        for (seen[0..seen_count]) |s| {
            if (std.mem.eql(u8, s, r.uri)) {
                is_dup = true;
                break;
            }
        }
        if (is_dup) continue;
        if (try isDuplicateAuthorTitle(&seen_authors, alloc, r.did, r.title)) continue;
        if (seen_count < 20) {
            seen[seen_count] = r.uri;
            seen_count += 1;
        }
        filtered_indices[filtered_count] = idx;
        filtered_count += 1;
    }

    // fetch content previews + cover images from local SQLite
    const extras = fetchLocalExtras(alloc, seen[0..seen_count]);

    // serialize results
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (filtered_indices[0..filtered_count]) |idx| {
        const r = results[idx];
        const doc_type: []const u8 = if (r.has_publication) "article" else "looseleaf";
        // prefer the local replica's URL fields over tpuf's stored attributes,
        // which can be stale (written at embed time). Falls back to tpuf values
        // when the doc isn't in the local replica yet.
        const platform = extras.platforms.get(r.uri) orelse r.platform;
        const base_path = extras.base_paths.get(r.uri) orelse r.base_path;
        const path = extras.paths.get(r.uri) orelse r.path;
        try jw.write(SearchResultJson{
            .type = doc_type,
            .uri = r.uri,
            .did = r.did,
            .title = r.title,
            .snippet = extras.snippets.get(r.uri) orelse "",
            .createdAt = r.created_at,
            .rkey = r.rkey,
            .basePath = base_path,
            .platform = platform,
            .path = path,
            .coverImage = extras.cover_images.get(r.uri) orelse "",
            .publicationName = extras.pub_names.get(r.uri) orelse "",
            .url = buildDocUrl(alloc, doc_type, platform, base_path, path, r.rkey, r.did),
        });
    }
    try jw.endArray();

    return try output.toOwnedSlice();
}

// --- local DB helpers (for semantic/similar results) ---

/// Extra fields fetched from local SQLite for semantic/similar results.
const LocalExtras = struct {
    snippets: std.StringHashMap([]const u8),
    cover_images: std.StringHashMap([]const u8),
    pub_names: std.StringHashMap([]const u8),
    // authoritative URL-determining fields from the local replica. tpuf stores
    // these as attributes at embed time, which go stale when a doc's platform/
    // path changes without re-embedding — so prefer these for buildDocUrl.
    platforms: std.StringHashMap([]const u8),
    base_paths: std.StringHashMap([]const u8),
    paths: std.StringHashMap([]const u8),
};

/// Fetch content previews, cover images, and publication names from local SQLite for a list of URIs.
/// Gracefully returns empty maps if local db is unavailable.
fn fetchLocalExtras(alloc: Allocator, uris: []const []const u8) LocalExtras {
    var snippets = std.StringHashMap([]const u8).init(alloc);
    var cover_images = std.StringHashMap([]const u8).init(alloc);
    var pub_names = std.StringHashMap([]const u8).init(alloc);
    var platforms = std.StringHashMap([]const u8).init(alloc);
    var base_paths = std.StringHashMap([]const u8).init(alloc);
    var paths = std.StringHashMap([]const u8).init(alloc);
    const empty: LocalExtras = .{ .snippets = snippets, .cover_images = cover_images, .pub_names = pub_names, .platforms = platforms, .base_paths = base_paths, .paths = paths };
    const local = db.getLocalDb() orelse return empty;
    for (uris) |uri| {
        var rows = local.query(
            "SELECT substr(content, 1, 200), COALESCE(cover_image, ''), COALESCE((SELECT name FROM publications WHERE uri = documents.publication_uri), ''), platform, COALESCE(base_path, ''), COALESCE(path, '') FROM documents WHERE uri = ?",
            .{uri},
        ) catch continue;
        defer rows.deinit();
        if (rows.next()) |row| {
            const preview = row.text(0);
            if (preview.len > 0) {
                const duped = alloc.dupe(u8, preview) catch continue;
                snippets.put(uri, duped) catch continue;
            }
            const cover = row.text(1);
            if (cover.len > 0) {
                const duped = alloc.dupe(u8, cover) catch continue;
                cover_images.put(uri, duped) catch continue;
            }
            const pub_name = row.text(2);
            if (pub_name.len > 0) {
                const duped = alloc.dupe(u8, pub_name) catch continue;
                pub_names.put(uri, duped) catch continue;
            }
            // authoritative URL fields — platform always present; dupe so they
            // outlive the row (rows.deinit frees the backing memory).
            if (alloc.dupe(u8, row.text(3))) |p| platforms.put(uri, p) catch {} else |_| {}
            if (alloc.dupe(u8, row.text(4))) |b| base_paths.put(uri, b) catch {} else |_| {}
            if (alloc.dupe(u8, row.text(5))) |pa| paths.put(uri, pa) catch {} else |_| {}
        }
    }
    return .{ .snippets = snippets, .cover_images = cover_images, .pub_names = pub_names, .platforms = platforms, .base_paths = base_paths, .paths = paths };
}

// --- JSON helpers (for hybrid search parsing) ---

fn jsonStr(obj: json.ObjectMap, key: []const u8) []const u8 {
    const val = obj.get(key) orelse return "";
    return switch (val) {
        .string => |s| s,
        else => "",
    };
}

/// Build FTS5 query from user input.
/// - bare words are OR'd together, prefix `*` on last word
/// - quoted phrases (`"..."`) are passed through for exact phrase matching
/// - unclosed quotes are treated as phrases with synthetic closing quote
/// Separators match FTS5 unicode61 tokenizer: any non-alphanumeric character
pub fn buildFtsQuery(alloc: Allocator, query: []const u8) ![]const u8 {
    if (query.len == 0) return "";

    // normalize: trim whitespace
    var start: usize = 0;
    var end: usize = query.len;
    while (start < end and query[start] == ' ') start += 1;
    while (end > start and query[end - 1] == ' ') end -= 1;
    if (start >= end) return "";

    const trimmed = query[start..end];

    // tokenize into phrases and words
    const TokenKind = enum { word, phrase };
    const Token = struct { kind: TokenKind, text: []const u8 };

    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(alloc);

    var i: usize = 0;
    while (i < trimmed.len) {
        if (trimmed[i] == '"') {
            // quoted phrase: scan to closing quote or end
            i += 1; // skip opening quote
            const inner_start = i;
            while (i < trimmed.len and trimmed[i] != '"') : (i += 1) {}
            const inner_end = i;
            if (i < trimmed.len) i += 1; // skip closing quote

            // only emit if inner text has alphanumeric content
            const inner = trimmed[inner_start..inner_end];
            for (inner) |c| {
                if (isAlnum(c)) {
                    try tokens.append(alloc, .{ .kind = .phrase, .text = inner });
                    break;
                }
            }
        } else if (isAlnum(trimmed[i])) {
            // bare word: scan alphanumeric run
            const word_start = i;
            while (i < trimmed.len and isAlnum(trimmed[i])) : (i += 1) {}
            const word = trimmed[word_start..i];
            // "OR" is an FTS5 operator — quote it so it's searched as a literal word
            const kind: TokenKind = if (std.mem.eql(u8, word, "OR")) .phrase else .word;
            try tokens.append(alloc, .{ .kind = kind, .text = word });
        } else {
            i += 1; // skip separator
        }
    }

    if (tokens.items.len == 0) return "";

    // build output: join with " OR ", prefix * on last token if it's a bare word
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    for (tokens.items, 0..) |token, idx| {
        if (idx > 0) {
            try out.appendSlice(alloc, " OR ");
        }
        switch (token.kind) {
            .word => {
                try out.appendSlice(alloc, token.text);
                if (idx == tokens.items.len - 1) {
                    try out.append(alloc, '*');
                }
            },
            .phrase => {
                try out.append(alloc, '"');
                try out.appendSlice(alloc, token.text);
                try out.append(alloc, '"');
            },
        }
    }

    return try out.toOwnedSlice(alloc);
}

fn isAlnum(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
}

// --- tests ---

test "buildFtsQuery: empty string" {
    const result = try buildFtsQuery(std.testing.allocator, "");
    try std.testing.expectEqualStrings("", result);
}

test "buildFtsQuery: whitespace only" {
    const result = try buildFtsQuery(std.testing.allocator, "   ");
    try std.testing.expectEqualStrings("", result);
}

test "buildFtsQuery: single word" {
    const result = try buildFtsQuery(std.testing.allocator, "hello");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello*", result);
}

test "buildFtsQuery: single word with whitespace" {
    const result = try buildFtsQuery(std.testing.allocator, "  hello  ");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello*", result);
}

test "buildFtsQuery: multiple words" {
    const result = try buildFtsQuery(std.testing.allocator, "cat dog");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("cat OR dog*", result);
}

test "buildFtsQuery: three words" {
    const result = try buildFtsQuery(std.testing.allocator, "one two three");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("one OR two OR three*", result);
}

test "buildFtsQuery: quoted phrase passthrough" {
    const result = try buildFtsQuery(std.testing.allocator, "\"exact phrase\"");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\"exact phrase\"", result);
}

test "buildFtsQuery: dots as separators" {
    const result = try buildFtsQuery(std.testing.allocator, "foo.bar");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("foo OR bar*", result);
}

test "buildFtsQuery: hyphens as separators" {
    const result = try buildFtsQuery(std.testing.allocator, "crypto-casino");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("crypto OR casino*", result);
}

test "buildFtsQuery: mixed punctuation" {
    const result = try buildFtsQuery(std.testing.allocator, "don't@stop_now");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("don OR t OR stop OR now*", result);
}

test "buildFtsQuery: embedded quoted phrase" {
    const result = try buildFtsQuery(std.testing.allocator, "python \"machine learning\" tutorial");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("python OR \"machine learning\" OR tutorial*", result);
}

test "buildFtsQuery: quoted phrase at start" {
    const result = try buildFtsQuery(std.testing.allocator, "\"exact phrase\" python");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\"exact phrase\" OR python*", result);
}

test "buildFtsQuery: quoted phrase at end" {
    const result = try buildFtsQuery(std.testing.allocator, "python \"machine learning\"");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("python OR \"machine learning\"", result);
}

test "buildFtsQuery: literal OR quoted to avoid FTS5 operator collision" {
    const result = try buildFtsQuery(std.testing.allocator, "bertha OR burton");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("bertha OR \"OR\" OR burton*", result);
}

test "buildFtsQuery: multiple ORs quoted" {
    const result = try buildFtsQuery(std.testing.allocator, "cat OR dog OR fish");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("cat OR \"OR\" OR dog OR \"OR\" OR fish*", result);
}

test "buildFtsQuery: OR at start quoted" {
    const result = try buildFtsQuery(std.testing.allocator, "OR cat dog");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\"OR\" OR cat OR dog*", result);
}

test "buildFtsQuery: OR at end" {
    const result = try buildFtsQuery(std.testing.allocator, "cat dog OR");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("cat OR dog OR \"OR\"", result);
}

test "buildFtsQuery: only OR" {
    const result = try buildFtsQuery(std.testing.allocator, "OR");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\"OR\"", result);
}

test "buildFtsQuery: unclosed quote" {
    const result = try buildFtsQuery(std.testing.allocator, "\"hello world");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\"hello world\"", result);
}

test "buildFtsQuery: empty quotes" {
    const result = try buildFtsQuery(std.testing.allocator, "\"\"");
    try std.testing.expectEqualStrings("", result);
}

test "buildFtsQuery: empty quotes with word" {
    const result = try buildFtsQuery(std.testing.allocator, "\"\" hello");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello*", result);
}

test "buildFtsQuery: mixed quotes and OR" {
    const result = try buildFtsQuery(std.testing.allocator, "\"exact phrase\" OR python");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\"exact phrase\" OR \"OR\" OR python*", result);
}

test "buildDocUrl: native leaflet doc uses rkey (no path)" {
    const url = buildDocUrl(std.testing.allocator, "article", "leaflet", "leaflet.pub", "", "abc123", "did:plc:x");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://leaflet.pub/abc123", url);
}

test "buildDocUrl: site.standard doc tagged leaflet uses path, not rkey" {
    // regression: feliciarondo.com site.standard.document records embed pub.leaflet.content
    // so get platform=leaflet, but must link to the author-set path — not the rkey
    const url = buildDocUrl(std.testing.allocator, "article", "leaflet", "feliciarondo.com", "/rondo-of-blog/2025/The-Heart-of-Peach/", "3m5i74ey7zs2c", "did:plc:2atpw7zrdrdptzqo7jw63rzv");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://feliciarondo.com/rondo-of-blog/2025/The-Heart-of-Peach/", url);
}

test "buildDocUrl: path without leading slash gets separator" {
    const url = buildDocUrl(std.testing.allocator, "article", "pckt", "example.com", "posts/hello", "rk", "did:plc:x");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://example.com/posts/hello", url);
}
