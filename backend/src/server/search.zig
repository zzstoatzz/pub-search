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

    fn fromRow(row: db.Row) Doc {
        return .{
            .uri = row.text(0),
            .did = row.text(1),
            .title = row.text(2),
            .snippet = row.text(3),
            .createdAt = row.text(4),
            .rkey = row.text(5),
            .basePath = row.text(6),
            .hasPublication = row.int(7) != 0,
            .platform = row.text(8),
            .path = row.text(9),
            .coverImage = row.text(10),
        };
    }

    fn fromLocalRow(row: db.LocalDb.Row) Doc {
        return .{
            .uri = row.text(0),
            .did = row.text(1),
            .title = row.text(2),
            .snippet = row.text(3),
            .createdAt = row.text(4),
            .rkey = row.text(5),
            .basePath = row.text(6),
            .hasPublication = row.int(7) != 0,
            .platform = row.text(8),
            .path = row.text(9),
            .coverImage = row.text(10),
        };
    }

    fn toJson(self: Doc) SearchResultJson {
        return .{
            .type = if (self.hasPublication) "article" else "looseleaf",
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
        };
    }
};

const DocsByTag = zql.Query(
    \\SELECT d.uri, d.did, d.title, '' as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image
    \\FROM documents d
    \\JOIN document_tags dt ON d.uri = dt.document_uri
    \\WHERE dt.tag = :tag
    \\ORDER BY d.created_at DESC LIMIT 40
);

const DocsByFtsAndTag = zql.Query(
    \\SELECT f.uri, d.did, d.title,
    \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\JOIN document_tags dt ON d.uri = dt.document_uri
    \\WHERE documents_fts MATCH :query AND dt.tag = :tag
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

const DocsByFts = zql.Query(
    \\SELECT f.uri, d.did, d.title,
    \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\WHERE documents_fts MATCH :query
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

const DocsByFtsAndSince = zql.Query(
    \\SELECT f.uri, d.did, d.title,
    \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\WHERE documents_fts MATCH :query AND d.created_at >= :since
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

const DocsByFtsAndPlatform = zql.Query(
    \\SELECT f.uri, d.did, d.title,
    \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\WHERE documents_fts MATCH :query AND d.platform = :platform
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

const DocsByFtsAndPlatformAndSince = zql.Query(
    \\SELECT f.uri, d.did, d.title,
    \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\WHERE documents_fts MATCH :query AND d.platform = :platform AND d.created_at >= :since
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

const DocsByTagAndPlatform = zql.Query(
    \\SELECT d.uri, d.did, d.title, '' as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image
    \\FROM documents d
    \\JOIN document_tags dt ON d.uri = dt.document_uri
    \\WHERE dt.tag = :tag AND d.platform = :platform
    \\ORDER BY d.created_at DESC LIMIT 40
);

const DocsByFtsAndTagAndPlatform = zql.Query(
    \\SELECT f.uri, d.did, d.title,
    \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\JOIN document_tags dt ON d.uri = dt.document_uri
    \\WHERE documents_fts MATCH :query AND dt.tag = :tag AND d.platform = :platform
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

const DocsByPlatform = zql.Query(
    \\SELECT d.uri, d.did, d.title, '' as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image
    \\FROM documents d
    \\WHERE d.platform = :platform
    \\ORDER BY d.created_at DESC LIMIT 40
);

const DocsByAuthor = zql.Query(
    \\SELECT d.uri, d.did, d.title, '' as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image
    \\FROM documents d
    \\WHERE d.did = :author
    \\ORDER BY d.created_at DESC LIMIT 40
);

const DocsByAuthorAndPlatform = zql.Query(
    \\SELECT d.uri, d.did, d.title, '' as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path,
    \\  COALESCE(d.cover_image, '') as cover_image
    \\FROM documents d
    \\WHERE d.did = :author AND d.platform = :platform
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
    \\  COALESCE(d.cover_image, '') as cover_image
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
    \\  COALESCE(d.cover_image, '') as cover_image
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
    \\  COALESCE(d.cover_image, '') as cover_image
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
    \\  COALESCE(d.cover_image, '') as cover_image
    \\FROM documents d
    \\JOIN publications p ON d.publication_uri = p.uri
    \\JOIN publications_fts pf ON p.uri = pf.uri
    \\WHERE publications_fts MATCH :query AND d.platform = :platform AND d.created_at >= :since
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

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
            .uri = row.text(0),
            .did = row.text(1),
            .name = row.text(2),
            .snippet = row.text(3),
            .rkey = row.text(4),
            .basePath = row.text(5),
            .platform = row.text(6),
        };
    }

    fn fromLocalRow(row: db.LocalDb.Row) Pub {
        return .{
            .uri = row.text(0),
            .did = row.text(1),
            .name = row.text(2),
            .snippet = row.text(3),
            .rkey = row.text(4),
            .basePath = row.text(5),
            .platform = row.text(6),
        };
    }

    fn toJson(self: Pub) SearchResultJson {
        return .{
            .type = "publication",
            .uri = self.uri,
            .did = self.did,
            .title = self.name,
            .snippet = self.snippet,
            .rkey = self.rkey,
            .basePath = self.basePath,
            .platform = self.platform,
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
    if (mode == .semantic) return searchSemantic(alloc, query, platform_filter, author_filter);
    return searchKeyword(alloc, query, tag_filter, platform_filter, since_filter, author_filter);
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
                try jw.write(doc.toJson());
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
                try jw.write(doc.toJson());
            }
        }
        try jw.endArray();
        return try output.toOwnedSlice();
    }

    // build batch of queries to execute in single HTTP request
    var statements: [3]db.Client.Statement = undefined;
    var stmt_count: usize = 0;

    // query 0: documents by content (always present if we have any filter)
    const doc_sql = getDocQuerySql(has_query, has_tag, has_platform, has_since);
    const doc_args = try getDocQueryArgs(alloc, fts_query, tag_filter, platform_filter, since_filter, has_query, has_tag, has_platform, has_since);
    if (doc_sql) |sql| {
        statements[stmt_count] = .{ .sql = sql, .args = doc_args };
        stmt_count += 1;
    }

    // query 1: documents by publication base_path (subdomain search)
    const run_basepath = has_query and !has_tag;
    if (run_basepath) {
        if (has_platform and has_since) {
            statements[stmt_count] = .{ .sql = DocsByPubBasePathAndPlatformAndSince.positional, .args = &.{ fts_query, platform_filter.?, since_filter.? } };
        } else if (has_platform) {
            statements[stmt_count] = .{ .sql = DocsByPubBasePathAndPlatform.positional, .args = &.{ fts_query, platform_filter.? } };
        } else if (has_since) {
            statements[stmt_count] = .{ .sql = DocsByPubBasePathAndSince.positional, .args = &.{ fts_query, since_filter.? } };
        } else {
            statements[stmt_count] = .{ .sql = DocsByPubBasePath.positional, .args = &.{fts_query} };
        }
        stmt_count += 1;
    }

    // query 2: publications (only when no tag/platform filter)
    const run_pubs = tag_filter == null and platform_filter == null and has_query;
    if (run_pubs) {
        statements[stmt_count] = .{ .sql = PubSearch.positional, .args = &.{fts_query} };
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
            try jw.write(doc.toJson());
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
                try jw.write(doc.toJson());
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
            try jw.write(pub_result.toJson());
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
            \\  COALESCE(d.cover_image, '') as cover_image
            \\FROM documents_fts f
            \\JOIN documents d ON f.uri = d.uri
            \\WHERE documents_fts MATCH ? AND d.platform = ?
            \\ORDER BY rank LIMIT 40
        , .{ fts_query, platform });
        defer rows.deinit();

        while (rows.next()) |row| {
            const doc = Doc.fromLocalRow(row);
            if (author_filter) |af| {
                if (!std.mem.eql(u8, doc.did, af)) continue;
            }
            if (since_filter) |since| {
                if (doc.createdAt.len > 0 and std.mem.order(u8, doc.createdAt, since) == .lt) continue;
            }
            if (try isDuplicateAuthorTitle(&seen_authors, alloc, doc.did, doc.title)) continue;
            const uri_dupe = try alloc.dupe(u8, doc.uri);
            try seen_uris.put(uri_dupe, {});
            try jw.write(doc.toJson());
        }

        // base_path search with platform
        var bp_rows = try local.query(
            \\SELECT d.uri, d.did, d.title, '' as snippet,
            \\  d.created_at, d.rkey, p.base_path,
            \\  1 as has_publication, d.platform, COALESCE(d.path, '') as path,
            \\  COALESCE(d.cover_image, '') as cover_image
            \\FROM documents d
            \\JOIN publications p ON d.publication_uri = p.uri
            \\JOIN publications_fts pf ON p.uri = pf.uri
            \\WHERE publications_fts MATCH ? AND d.platform = ?
            \\ORDER BY rank LIMIT 40
        , .{ fts_query, platform });
        defer bp_rows.deinit();

        while (bp_rows.next()) |row| {
            const doc = Doc.fromLocalRow(row);
            if (author_filter) |af| {
                if (!std.mem.eql(u8, doc.did, af)) continue;
            }
            if (since_filter) |since| {
                if (doc.createdAt.len > 0 and std.mem.order(u8, doc.createdAt, since) == .lt) continue;
            }
            if (!seen_uris.contains(doc.uri) and !try isDuplicateAuthorTitle(&seen_authors, alloc, doc.did, doc.title)) {
                try jw.write(doc.toJson());
            }
        }
    } else {
        // no platform filter
        var rows = try local.query(
            \\SELECT f.uri, d.did, d.title,
            \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
            \\  d.created_at, d.rkey, d.base_path, d.has_publication,
            \\  d.platform, COALESCE(d.path, '') as path,
            \\  COALESCE(d.cover_image, '') as cover_image
            \\FROM documents_fts f
            \\JOIN documents d ON f.uri = d.uri
            \\WHERE documents_fts MATCH ?
            \\ORDER BY rank LIMIT 40
        , .{fts_query});
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
                if (since_filter) |since| {
                    if (doc.createdAt.len > 0 and std.mem.order(u8, doc.createdAt, since) == .lt) continue;
                }
                if (try isDuplicateAuthorTitle(&seen_authors, alloc, doc.did, doc.title)) continue;
                const uri_dupe = try alloc.dupe(u8, doc.uri);
                try seen_uris.put(uri_dupe, {});
                try jw.write(doc.toJson());
                doc_count += 1;
            }
            logfire.info("search.iterate.docs_fts rows={d}", .{doc_count});
        }

        // base_path search
        var bp_rows = try local.query(
            \\SELECT d.uri, d.did, d.title, '' as snippet,
            \\  d.created_at, d.rkey, p.base_path,
            \\  1 as has_publication, d.platform, COALESCE(d.path, '') as path,
            \\  COALESCE(d.cover_image, '') as cover_image
            \\FROM documents d
            \\JOIN publications p ON d.publication_uri = p.uri
            \\JOIN publications_fts pf ON p.uri = pf.uri
            \\WHERE publications_fts MATCH ?
            \\ORDER BY rank LIMIT 40
        , .{fts_query});
        defer bp_rows.deinit();

        {
            const iter_span = logfire.span("search.iterate.base_path", .{});
            defer iter_span.end();
            var bp_count: u32 = 0;
            while (bp_rows.next()) |row| {
                const doc = Doc.fromLocalRow(row);
                if (author_filter) |af| {
                    if (!std.mem.eql(u8, doc.did, af)) { bp_count += 1; continue; }
                }
                if (since_filter) |since| {
                    if (doc.createdAt.len > 0 and std.mem.order(u8, doc.createdAt, since) == .lt) {
                        bp_count += 1;
                        continue;
                    }
                }
                if (!seen_uris.contains(doc.uri) and !try isDuplicateAuthorTitle(&seen_authors, alloc, doc.did, doc.title)) {
                    try jw.write(doc.toJson());
                }
                bp_count += 1;
            }
            logfire.info("search.iterate.base_path rows={d}", .{bp_count});
        }

        // publication search
        var pub_rows = try local.query(
            \\SELECT f.uri, p.did, p.name,
            \\  snippet(publications_fts, 2, '', '', '...', 32) as snippet,
            \\  p.rkey, p.base_path, p.platform
            \\FROM publications_fts f
            \\JOIN publications p ON f.uri = p.uri
            \\WHERE publications_fts MATCH ?
            \\ORDER BY rank LIMIT 10
        , .{fts_query});
        defer pub_rows.deinit();

        {
            const iter_span = logfire.span("search.iterate.pubs_fts", .{});
            defer iter_span.end();
            var pub_count: u32 = 0;
            while (pub_rows.next()) |row| {
                const pub_result = Pub.fromLocalRow(row);
                if (author_filter) |af| {
                    if (!std.mem.eql(u8, pub_result.did, af)) { pub_count += 1; continue; }
                }
                try jw.write(pub_result.toJson());
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
        try jw.write(SearchResultJson{
            .type = if (r.has_publication) "article" else "looseleaf",
            .uri = r.uri,
            .did = r.did,
            .title = r.title,
            .snippet = extras.snippets.get(r.uri) orelse "",
            .createdAt = r.created_at,
            .rkey = r.rkey,
            .basePath = r.base_path,
            .platform = r.platform,
            .path = r.path,
            .coverImage = extras.cover_images.get(r.uri) orelse "",
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
    const sem_json = searchSemantic(alloc, query, platform_filter, author_filter) catch |err| blk: {
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
fn searchSemantic(alloc: Allocator, query: []const u8, platform_filter: ?[]const u8, author_filter: ?[]const u8) ![]const u8 {
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
        if (platform_filter) |pf| {
            if (!std.mem.eql(u8, r.platform, pf)) continue;
        }
        if (author_filter) |af| {
            if (!std.mem.eql(u8, r.did, af)) continue;
        }
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
        try jw.write(SearchResultJson{
            .type = if (r.has_publication) "article" else "looseleaf",
            .uri = r.uri,
            .did = r.did,
            .title = r.title,
            .snippet = extras.snippets.get(r.uri) orelse "",
            .createdAt = r.created_at,
            .rkey = r.rkey,
            .basePath = r.base_path,
            .platform = r.platform,
            .path = r.path,
            .coverImage = extras.cover_images.get(r.uri) orelse "",
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
};

/// Fetch content previews and cover images from local SQLite for a list of URIs.
/// Gracefully returns empty maps if local db is unavailable.
fn fetchLocalExtras(alloc: Allocator, uris: []const []const u8) LocalExtras {
    var snippets = std.StringHashMap([]const u8).init(alloc);
    var cover_images = std.StringHashMap([]const u8).init(alloc);
    const local = db.getLocalDb() orelse return .{ .snippets = snippets, .cover_images = cover_images };
    for (uris) |uri| {
        var rows = local.query(
            "SELECT substr(content, 1, 200), COALESCE(cover_image, '') FROM documents WHERE uri = ?",
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
        }
    }
    return .{ .snippets = snippets, .cover_images = cover_images };
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
