const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const zql = @import("zql");
const logfire = @import("logfire");
const db = @import("db/mod.zig");
const tpuf = @import("tpuf.zig");

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
        };
    }
};

const DocsByTag = zql.Query(
    \\SELECT d.uri, d.did, d.title, '' as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path
    \\FROM documents d
    \\JOIN document_tags dt ON d.uri = dt.document_uri
    \\WHERE dt.tag = :tag
    \\ORDER BY d.created_at DESC LIMIT 40
);

const DocsByFtsAndTag = zql.Query(
    \\SELECT f.uri, d.did, d.title,
    \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path
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
    \\  d.platform, COALESCE(d.path, '') as path
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\WHERE documents_fts MATCH :query
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

const DocsByFtsAndSince = zql.Query(
    \\SELECT f.uri, d.did, d.title,
    \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\WHERE documents_fts MATCH :query AND d.created_at >= :since
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

const DocsByFtsAndPlatform = zql.Query(
    \\SELECT f.uri, d.did, d.title,
    \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\WHERE documents_fts MATCH :query AND d.platform = :platform
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

const DocsByFtsAndPlatformAndSince = zql.Query(
    \\SELECT f.uri, d.did, d.title,
    \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\WHERE documents_fts MATCH :query AND d.platform = :platform AND d.created_at >= :since
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

const DocsByTagAndPlatform = zql.Query(
    \\SELECT d.uri, d.did, d.title, '' as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path
    \\FROM documents d
    \\JOIN document_tags dt ON d.uri = dt.document_uri
    \\WHERE dt.tag = :tag AND d.platform = :platform
    \\ORDER BY d.created_at DESC LIMIT 40
);

const DocsByFtsAndTagAndPlatform = zql.Query(
    \\SELECT f.uri, d.did, d.title,
    \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\JOIN document_tags dt ON d.uri = dt.document_uri
    \\WHERE documents_fts MATCH :query AND dt.tag = :tag AND d.platform = :platform
    \\ORDER BY rank + (julianday('now') - julianday(d.created_at)) / 30.0 LIMIT 40
);

const DocsByPlatform = zql.Query(
    \\SELECT d.uri, d.did, d.title, '' as snippet,
    \\  d.created_at, d.rkey, d.base_path, d.has_publication,
    \\  d.platform, COALESCE(d.path, '') as path
    \\FROM documents d
    \\WHERE d.platform = :platform
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
    \\  d.platform, COALESCE(d.path, '') as path
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
    \\  d.platform, COALESCE(d.path, '') as path
    \\FROM documents d
    \\JOIN publications p ON d.publication_uri = p.uri
    \\JOIN publications_fts pf ON p.uri = pf.uri
    \\WHERE publications_fts MATCH :query AND d.platform = :platform
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

pub fn search(alloc: Allocator, query: []const u8, tag_filter: ?[]const u8, platform_filter: ?[]const u8, since_filter: ?[]const u8, mode: SearchMode) ![]const u8 {
    if (mode == .hybrid) return searchHybrid(alloc, query, tag_filter, platform_filter, since_filter);
    if (mode == .semantic) return searchSemantic(alloc, query, platform_filter);
    return searchKeyword(alloc, query, tag_filter, platform_filter, since_filter);
}

/// Keyword search: FTS5 via local SQLite or Turso fallback.
fn searchKeyword(alloc: Allocator, query: []const u8, tag_filter: ?[]const u8, platform_filter: ?[]const u8, since_filter: ?[]const u8) ![]const u8 {
    // try local SQLite first (faster for FTS queries)
    if (db.getLocalDb()) |local| {
        if (searchLocal(alloc, local, query, tag_filter, platform_filter, since_filter)) |result| {
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
        if (has_platform) {
            statements[stmt_count] = .{ .sql = DocsByPubBasePathAndPlatform.positional, .args = &.{ fts_query, platform_filter.? } };
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
            if (!seen_uris.contains(doc.uri)) {
                try jw.write(doc.toJson());
            }
        }
        query_idx += 1;
    }

    // process query 2: publication results
    if (run_pubs) {
        for (batch.get(query_idx)) |row| {
            try jw.write(Pub.fromRow(row).toJson());
        }
    }

    try jw.endArray();
    return try output.toOwnedSlice();
}

/// Local SQLite search (FTS queries only, no vector similarity)
/// Simplified version - just handles basic FTS query case to get started
fn searchLocal(alloc: Allocator, local: *db.LocalDb, query: []const u8, tag_filter: ?[]const u8, platform_filter: ?[]const u8, since_filter: ?[]const u8) ![]const u8 {
    // only handle basic FTS queries for now (most common case)
    // fall back to Turso for complex filter combinations
    if (query.len == 0 or tag_filter != null or since_filter != null) {
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

    // document content search
    if (platform_filter) |platform| {
        var rows = try local.query(
            \\SELECT f.uri, d.did, d.title,
            \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
            \\  d.created_at, d.rkey, d.base_path, d.has_publication,
            \\  d.platform, COALESCE(d.path, '') as path
            \\FROM documents_fts f
            \\JOIN documents d ON f.uri = d.uri
            \\WHERE documents_fts MATCH ? AND d.platform = ?
            \\ORDER BY rank LIMIT 40
        , .{ fts_query, platform });
        defer rows.deinit();

        while (rows.next()) |row| {
            const doc = Doc.fromLocalRow(row);
            const uri_dupe = try alloc.dupe(u8, doc.uri);
            try seen_uris.put(uri_dupe, {});
            try jw.write(doc.toJson());
        }

        // base_path search with platform
        var bp_rows = try local.query(
            \\SELECT d.uri, d.did, d.title, '' as snippet,
            \\  d.created_at, d.rkey, p.base_path,
            \\  1 as has_publication, d.platform, COALESCE(d.path, '') as path
            \\FROM documents d
            \\JOIN publications p ON d.publication_uri = p.uri
            \\JOIN publications_fts pf ON p.uri = pf.uri
            \\WHERE publications_fts MATCH ? AND d.platform = ?
            \\ORDER BY rank LIMIT 40
        , .{ fts_query, platform });
        defer bp_rows.deinit();

        while (bp_rows.next()) |row| {
            const doc = Doc.fromLocalRow(row);
            if (!seen_uris.contains(doc.uri)) {
                try jw.write(doc.toJson());
            }
        }
    } else {
        // no platform filter
        var rows = try local.query(
            \\SELECT f.uri, d.did, d.title,
            \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
            \\  d.created_at, d.rkey, d.base_path, d.has_publication,
            \\  d.platform, COALESCE(d.path, '') as path
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
            \\  1 as has_publication, d.platform, COALESCE(d.path, '') as path
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
                if (!seen_uris.contains(doc.uri)) {
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
                try jw.write(Pub.fromLocalRow(row).toJson());
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

    // serialize, filtering out the source URI
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    var count: usize = 0;
    for (results) |r| {
        if (std.mem.eql(u8, r.uri, uri)) continue;
        if (count >= limit) break;
        try jw.write(SearchResultJson{
            .type = if (r.has_publication) "article" else "looseleaf",
            .uri = r.uri,
            .did = r.did,
            .title = r.title,
            .snippet = "",
            .createdAt = r.created_at,
            .rkey = r.rkey,
            .basePath = r.base_path,
            .platform = r.platform,
            .path = r.path,
        });
        count += 1;
    }
    try jw.endArray();

    return try output.toOwnedSlice();
}

/// Hybrid search: run keyword + semantic, merge with Reciprocal Rank Fusion.
/// score(doc) = 1/(k + rank_keyword) + 1/(k + rank_semantic), k=60
fn searchHybrid(alloc: Allocator, query: []const u8, tag_filter: ?[]const u8, platform_filter: ?[]const u8, since_filter: ?[]const u8) ![]const u8 {
    if (query.len == 0) return try alloc.dupe(u8, "[]");

    const span = logfire.span("search.hybrid", .{});
    defer span.end();

    // 1. keyword search (~10ms via local SQLite)
    const kw_json = searchKeyword(alloc, query, tag_filter, platform_filter, since_filter) catch |err| blk: {
        logfire.warn("search.hybrid: keyword failed: {}", .{err});
        break :blk try alloc.dupe(u8, "[]");
    };

    // 2. semantic search (~550ms via voyage + tpuf)
    const sem_json = searchSemantic(alloc, query, platform_filter) catch |err| blk: {
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

    // 6. serialize top 20 with source annotation
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();

    const limit = @min(scored.items.len, 20);
    for (scored.items[0..limit]) |entry| {
        const bits = source_bits.get(entry.uri) orelse 0;
        // prefer keyword version (has FTS snippet)
        const obj = kw_objects.get(entry.uri) orelse sem_objects.get(entry.uri) orelse continue;

        const source_label: []const u8 = switch (bits) {
            0b01 => "keyword",
            0b10 => "semantic",
            0b11 => "keyword+semantic",
            else => "",
        };

        try jw.beginObject();
        // write all standard fields from the source object
        inline for (.{ "type", "uri", "did", "title", "snippet", "rkey", "basePath", "platform", "path" }) |field| {
            try jw.objectField(field);
            try jw.write(jsonStr(obj, field));
        }
        try jw.objectField("createdAt");
        try jw.write(jsonStr(obj, "createdAt"));
        try jw.objectField("source");
        try jw.write(source_label);
        try jw.endObject();
    }

    try jw.endArray();
    return try output.toOwnedSlice();
}

/// Semantic search: embed query via Voyage, ANN search via turbopuffer.
fn searchSemantic(alloc: Allocator, query: []const u8, platform_filter: ?[]const u8) ![]const u8 {
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

    // serialize results, filtering by distance + platform + dedup, capped at 20
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    // track seen URIs to deduplicate
    var seen: [20][]const u8 = undefined;
    var seen_count: usize = 0;

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    var count: usize = 0;
    for (results) |r| {
        if (count >= 20) break;
        // skip documents with empty/test titles
        if (r.title.len == 0) continue;
        if (platform_filter) |pf| {
            if (!std.mem.eql(u8, r.platform, pf)) continue;
        }
        // deduplicate by URI
        var is_dup = false;
        for (seen[0..seen_count]) |s| {
            if (std.mem.eql(u8, s, r.uri)) {
                is_dup = true;
                break;
            }
        }
        if (is_dup) continue;
        if (seen_count < 20) {
            seen[seen_count] = r.uri;
            seen_count += 1;
        }
        count += 1;
        try jw.write(SearchResultJson{
            .type = if (r.has_publication) "article" else "looseleaf",
            .uri = r.uri,
            .did = r.did,
            .title = r.title,
            .snippet = "",
            .createdAt = r.created_at,
            .rkey = r.rkey,
            .basePath = r.base_path,
            .platform = r.platform,
            .path = r.path,
        });
    }
    try jw.endArray();

    return try output.toOwnedSlice();
}

// --- JSON helpers (for hybrid search parsing) ---

fn jsonStr(obj: json.ObjectMap, key: []const u8) []const u8 {
    const val = obj.get(key) orelse return "";
    return switch (val) {
        .string => |s| s,
        else => "",
    };
}

/// Build FTS5 query with OR between terms: "cat dog" -> "cat OR dog*"
/// Uses OR for better recall with BM25 ranking (more matches = higher score)
/// Quoted queries are passed through as phrase matches: "exact phrase" -> "exact phrase"
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

    // quoted phrase: pass through to FTS5 for exact phrase matching
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return try alloc.dupe(u8, trimmed);
    }

    // count words and total length
    // match FTS5 unicode61 tokenizer: non-alphanumeric = separator
    var word_count: usize = 0;
    var total_word_len: usize = 0;
    var in_word = false;
    for (trimmed) |c| {
        const is_alnum = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
        if (!is_alnum) {
            in_word = false;
        } else {
            if (!in_word) word_count += 1;
            in_word = true;
            total_word_len += 1;
        }
    }

    if (word_count == 0) return "";

    // single word: just add prefix wildcard
    if (word_count == 1) {
        const buf = try alloc.alloc(u8, total_word_len + 1);
        var pos: usize = 0;
        for (trimmed) |c| {
            const is_alnum = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
            if (is_alnum) {
                buf[pos] = c;
                pos += 1;
            }
        }
        buf[pos] = '*';
        return buf;
    }

    // multiple words: join with " OR ", prefix on last
    // size = word chars + (n-1) * 4 for " OR " + 1 for "*"
    const buf_len = total_word_len + (word_count - 1) * 4 + 1;
    const buf = try alloc.alloc(u8, buf_len);

    var pos: usize = 0;
    var current_word: usize = 0;
    in_word = false;

    for (trimmed) |c| {
        const is_alnum = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
        if (!is_alnum) {
            if (in_word) {
                // end of word - add " OR " if not last
                current_word += 1;
                if (current_word < word_count) {
                    @memcpy(buf[pos .. pos + 4], " OR ");
                    pos += 4;
                }
            }
            in_word = false;
        } else {
            buf[pos] = c;
            pos += 1;
            in_word = true;
        }
    }
    buf[pos] = '*';
    return buf;
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
