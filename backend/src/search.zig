const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const zql = @import("zql");
const db = @import("db/mod.zig");
const stats = @import("stats.zig");

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
    \\  d.created_at, d.rkey,
    \\  COALESCE(p.base_path, (SELECT base_path FROM publications WHERE did = d.did LIMIT 1), '') as base_path,
    \\  CASE WHEN d.publication_uri != '' THEN 1 ELSE 0 END as has_publication,
    \\  d.platform, COALESCE(d.path, '') as path
    \\FROM documents d
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\JOIN document_tags dt ON d.uri = dt.document_uri
    \\WHERE dt.tag = :tag
    \\ORDER BY d.created_at DESC LIMIT 40
);

const DocsByFtsAndTag = zql.Query(
    \\SELECT f.uri, d.did, d.title,
    \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
    \\  d.created_at, d.rkey,
    \\  COALESCE(p.base_path, (SELECT base_path FROM publications WHERE did = d.did LIMIT 1), '') as base_path,
    \\  CASE WHEN d.publication_uri != '' THEN 1 ELSE 0 END as has_publication,
    \\  d.platform, COALESCE(d.path, '') as path
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\JOIN document_tags dt ON d.uri = dt.document_uri
    \\WHERE documents_fts MATCH :query AND dt.tag = :tag
    \\ORDER BY rank LIMIT 40
);

const DocsByFts = zql.Query(
    \\SELECT f.uri, d.did, d.title,
    \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
    \\  d.created_at, d.rkey,
    \\  COALESCE(p.base_path, (SELECT base_path FROM publications WHERE did = d.did LIMIT 1), '') as base_path,
    \\  CASE WHEN d.publication_uri != '' THEN 1 ELSE 0 END as has_publication,
    \\  d.platform, COALESCE(d.path, '') as path
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\WHERE documents_fts MATCH :query
    \\ORDER BY rank LIMIT 40
);

const DocsByFtsAndPlatform = zql.Query(
    \\SELECT f.uri, d.did, d.title,
    \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
    \\  d.created_at, d.rkey,
    \\  COALESCE(p.base_path, (SELECT base_path FROM publications WHERE did = d.did LIMIT 1), '') as base_path,
    \\  CASE WHEN d.publication_uri != '' THEN 1 ELSE 0 END as has_publication,
    \\  d.platform, COALESCE(d.path, '') as path
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\WHERE documents_fts MATCH :query AND d.platform = :platform
    \\ORDER BY rank LIMIT 40
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
    \\ORDER BY rank LIMIT 10
);

pub fn search(alloc: Allocator, query: []const u8, tag_filter: ?[]const u8, platform_filter: ?[]const u8) ![]const u8 {
    const c = db.getClient() orelse return error.NotInitialized;

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();

    const fts_query = try buildFtsQuery(alloc, query);

    // search documents
    var doc_result = if (query.len == 0 and tag_filter != null)
        c.query(DocsByTag.positional, DocsByTag.bind(.{ .tag = tag_filter.? })) catch null
    else if (tag_filter) |tag|
        c.query(DocsByFtsAndTag.positional, DocsByFtsAndTag.bind(.{ .query = fts_query, .tag = tag })) catch null
    else if (platform_filter) |pf|
        c.query(DocsByFtsAndPlatform.positional, DocsByFtsAndPlatform.bind(.{ .query = fts_query, .platform = pf })) catch null
    else
        c.query(DocsByFts.positional, DocsByFts.bind(.{ .query = fts_query })) catch null;

    if (doc_result) |*res| {
        defer res.deinit();
        for (res.rows) |row| {
            try jw.write(Doc.fromRow(row).toJson());
        }
    }

    // publications are excluded when filtering by tag or platform
    // (platform filter is for documents only - publications don't have meaningful platform distinction)
    if (tag_filter == null and platform_filter == null) {
        var pub_result = c.query(
            PubSearch.positional,
            PubSearch.bind(.{ .query = fts_query }),
        ) catch null;

        if (pub_result) |*res| {
            defer res.deinit();
            for (res.rows) |row| {
                try jw.write(Pub.fromRow(row).toJson());
            }
        }
    }

    try jw.endArray();
    return try output.toOwnedSlice();
}

/// Find documents similar to a given document using vector similarity
/// Uses brute-force cosine distance with caching (cache invalidated when doc count changes)
pub fn findSimilar(alloc: Allocator, uri: []const u8, limit: usize) ![]const u8 {
    const c = db.getClient() orelse return error.NotInitialized;

    // get current doc count (for cache invalidation)
    const doc_count = getEmbeddedDocCount(c) orelse return error.QueryFailed;

    // check cache
    if (getCachedSimilar(alloc, c, uri, doc_count)) |cached| {
        stats.recordCacheHit();
        return cached;
    }
    stats.recordCacheMiss();

    // cache miss - compute similarity
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var limit_buf: [8]u8 = undefined;
    const limit_str = std.fmt.bufPrint(&limit_buf, "{d}", .{limit}) catch "5";

    // brute-force cosine similarity search (no vector index needed)
    var res = c.query(
        \\SELECT d2.uri, d2.did, d2.title, '' as snippet,
        \\  d2.created_at, d2.rkey,
        \\  COALESCE(p.base_path, (SELECT base_path FROM publications WHERE did = d2.did LIMIT 1), '') as base_path,
        \\  CASE WHEN d2.publication_uri != '' THEN 1 ELSE 0 END as has_publication,
        \\  d2.platform, COALESCE(d2.path, '') as path
        \\FROM documents d1, documents d2
        \\LEFT JOIN publications p ON d2.publication_uri = p.uri
        \\WHERE d1.uri = ?
        \\  AND d2.uri != d1.uri
        \\  AND d1.embedding IS NOT NULL
        \\  AND d2.embedding IS NOT NULL
        \\ORDER BY vector_distance_cos(d1.embedding, d2.embedding)
        \\LIMIT ?
    , &.{ uri, limit_str }) catch {
        try output.writer.writeAll("[]");
        return try output.toOwnedSlice();
    };
    defer res.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (res.rows) |row| try jw.write(Doc.fromRow(row).toJson());
    try jw.endArray();

    const results = try output.toOwnedSlice();

    // cache the results (fire and forget)
    cacheSimilarResults(c, uri, results, doc_count);

    return results;
}

fn getEmbeddedDocCount(c: *db.Client) ?i64 {
    var res = c.query("SELECT COUNT(*) FROM documents WHERE embedding IS NOT NULL", &.{}) catch return null;
    defer res.deinit();
    if (res.rows.len == 0) return null;
    return res.rows[0].int(0);
}

fn getCachedSimilar(alloc: Allocator, c: *db.Client, uri: []const u8, current_doc_count: i64) ?[]const u8 {
    var count_buf: [20]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{current_doc_count}) catch return null;

    var res = c.query(
        "SELECT results FROM similarity_cache WHERE source_uri = ? AND doc_count = ?",
        &.{ uri, count_str },
    ) catch return null;
    defer res.deinit();

    if (res.rows.len == 0) return null;
    return alloc.dupe(u8, res.rows[0].text(0)) catch null;
}

fn cacheSimilarResults(c: *db.Client, uri: []const u8, results: []const u8, doc_count: i64) void {
    var count_buf: [20]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{doc_count}) catch return;

    var ts_buf: [20]u8 = undefined;
    const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch return;

    c.exec(
        "INSERT OR REPLACE INTO similarity_cache (source_uri, results, doc_count, computed_at) VALUES (?, ?, ?, ?)",
        &.{ uri, results, count_str, ts_str },
    ) catch {};
}

/// Build FTS5 query with OR between terms: "cat dog" -> "cat OR dog*"
/// Uses OR for better recall with BM25 ranking (more matches = higher score)
/// Quoted queries are passed through as phrase matches: "exact phrase" -> "exact phrase"
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
    var word_count: usize = 0;
    var total_word_len: usize = 0;
    var in_word = false;
    for (trimmed) |c| {
        const is_sep = (c == ' ' or c == '.');
        if (is_sep) {
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
            if (c != ' ' and c != '.') {
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
        const is_sep = (c == ' ' or c == '.');
        if (is_sep) {
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
