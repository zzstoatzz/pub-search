const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

const zql = @import("zql");
const Client = @import("Client.zig");
const schema = @import("schema.zig");
const result = @import("result.zig");

// activity tracking - ring buffer for real-time search activity
const ACTIVITY_SLOTS = 60;
const ACTIVITY_TICK_MS = 100;
var activity_counts: [ACTIVITY_SLOTS]u16 = .{0} ** ACTIVITY_SLOTS;
var activity_slot: usize = 0;
var activity_mutex: std.Thread.Mutex = .{};
var activity_thread: ?std.Thread = null;

fn activityTickLoop() void {
    while (true) {
        std.Thread.sleep(ACTIVITY_TICK_MS * std.time.ns_per_ms);
        activity_mutex.lock();
        activity_slot = (activity_slot + 1) % ACTIVITY_SLOTS;
        activity_counts[activity_slot] = 0;
        activity_mutex.unlock();
    }
}

pub fn initActivity() void {
    activity_thread = std.Thread.spawn(.{}, activityTickLoop, .{}) catch null;
}

pub fn getActivityCounts() [ACTIVITY_SLOTS]u16 {
    activity_mutex.lock();
    defer activity_mutex.unlock();
    var result_arr: [ACTIVITY_SLOTS]u16 = undefined;
    for (0..ACTIVITY_SLOTS) |i| {
        const idx = (activity_slot + 1 + i) % ACTIVITY_SLOTS;
        result_arr[i] = activity_counts[idx];
    }
    return result_arr;
}

fn recordActivity() void {
    activity_mutex.lock();
    defer activity_mutex.unlock();
    activity_counts[activity_slot] +|= 1;
}

pub const Row = result.Row;
pub const BatchResult = result.BatchResult;
pub const Statement = Client.Statement;

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var client: ?Client = null;

pub fn init() !void {
    client = try Client.init(gpa.allocator());
    try schema.init(&client.?);
}

pub fn getClient() ?*Client {
    if (client) |*c| return c;
    return null;
}

pub fn insertDocument(
    uri: []const u8,
    did: []const u8,
    rkey: []const u8,
    title: []const u8,
    content: []const u8,
    created_at: ?[]const u8,
    publication_uri: ?[]const u8,
    tags: []const []const u8,
) !void {
    var c = &(client orelse return error.NotInitialized);

    try c.exec(
        "INSERT OR REPLACE INTO documents (uri, did, rkey, title, content, created_at, publication_uri) VALUES (?, ?, ?, ?, ?, ?, ?)",
        &.{ uri, did, rkey, title, content, created_at orelse "", publication_uri orelse "" },
    );

    // update FTS index
    c.exec("DELETE FROM documents_fts WHERE uri = ?", &.{uri}) catch {};
    c.exec(
        "INSERT INTO documents_fts (uri, title, content) VALUES (?, ?, ?)",
        &.{ uri, title, content },
    ) catch {};

    // update tags
    c.exec("DELETE FROM document_tags WHERE document_uri = ?", &.{uri}) catch {};
    for (tags) |tag| {
        c.exec(
            "INSERT OR IGNORE INTO document_tags (document_uri, tag) VALUES (?, ?)",
            &.{ uri, tag },
        ) catch {};
    }
}

pub fn insertPublication(
    uri: []const u8,
    did: []const u8,
    rkey: []const u8,
    name: []const u8,
    description: ?[]const u8,
    base_path: ?[]const u8,
) !void {
    var c = &(client orelse return error.NotInitialized);

    try c.exec(
        "INSERT OR REPLACE INTO publications (uri, did, rkey, name, description, base_path) VALUES (?, ?, ?, ?, ?, ?)",
        &.{ uri, did, rkey, name, description orelse "", base_path orelse "" },
    );

    // update FTS index
    c.exec("DELETE FROM publications_fts WHERE uri = ?", &.{uri}) catch {};
    c.exec(
        "INSERT INTO publications_fts (uri, name, description) VALUES (?, ?, ?)",
        &.{ uri, name, description orelse "" },
    ) catch {};
}

pub fn deleteDocument(uri: []const u8) void {
    var c = &(client orelse return);
    // record tombstone
    var ts_buf: [20]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch "0";
    c.exec(
        "INSERT OR REPLACE INTO tombstones (uri, record_type, deleted_at) VALUES (?, 'document', ?)",
        &.{ uri, ts },
    ) catch {};
    // delete record
    c.exec("DELETE FROM documents WHERE uri = ?", &.{uri}) catch {};
    c.exec("DELETE FROM documents_fts WHERE uri = ?", &.{uri}) catch {};
    c.exec("DELETE FROM document_tags WHERE document_uri = ?", &.{uri}) catch {};
}

pub fn deletePublication(uri: []const u8) void {
    var c = &(client orelse return);
    // record tombstone
    var ts_buf: [20]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch "0";
    c.exec(
        "INSERT OR REPLACE INTO tombstones (uri, record_type, deleted_at) VALUES (?, 'publication', ?)",
        &.{ uri, ts },
    ) catch {};
    // delete record
    c.exec("DELETE FROM publications WHERE uri = ?", &.{uri}) catch {};
    c.exec("DELETE FROM publications_fts WHERE uri = ?", &.{uri}) catch {};
}

// JSON output types for search results
const SearchResultJson = struct {
    type: []const u8,
    uri: []const u8,
    did: []const u8,
    title: []const u8,
    snippet: []const u8,
    createdAt: []const u8 = "",
    rkey: []const u8,
    basePath: []const u8,
};

const TagJson = struct { tag: []const u8, count: i64 };
const PopularJson = struct { query: []const u8, count: i64 };

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

    fn fromRow(row: Row) Doc {
        return .{
            .uri = row.text(0),
            .did = row.text(1),
            .title = row.text(2),
            .snippet = row.text(3),
            .createdAt = row.text(4),
            .rkey = row.text(5),
            .basePath = row.text(6),
            .hasPublication = row.int(7) != 0,
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
        };
    }
};

const DocsByTag = zql.Query(
    \\SELECT d.uri, d.did, d.title, '' as snippet,
    \\  d.created_at, d.rkey, p.base_path,
    \\  CASE WHEN d.publication_uri != '' THEN 1 ELSE 0 END as has_publication
    \\FROM documents d
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\JOIN document_tags dt ON d.uri = dt.document_uri
    \\WHERE dt.tag = :tag
    \\ORDER BY d.created_at DESC LIMIT 40
);

const DocsByFtsAndTag = zql.Query(
    \\SELECT f.uri, d.did, d.title,
    \\  snippet(documents_fts, 2, '', '', '...', 32) as snippet,
    \\  d.created_at, d.rkey, p.base_path,
    \\  CASE WHEN d.publication_uri != '' THEN 1 ELSE 0 END as has_publication
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
    \\  d.created_at, d.rkey, p.base_path,
    \\  CASE WHEN d.publication_uri != '' THEN 1 ELSE 0 END as has_publication
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\WHERE documents_fts MATCH :query
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

    fn fromRow(row: Row) Pub {
        return .{
            .uri = row.text(0),
            .did = row.text(1),
            .name = row.text(2),
            .snippet = row.text(3),
            .rkey = row.text(4),
            .basePath = row.text(5),
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
        };
    }
};

const PubSearch = zql.Query(
    \\SELECT f.uri, p.did, p.name,
    \\  snippet(publications_fts, 2, '', '', '...', 32) as snippet,
    \\  p.rkey, p.base_path
    \\FROM publications_fts f
    \\JOIN publications p ON f.uri = p.uri
    \\WHERE publications_fts MATCH :query
    \\ORDER BY rank LIMIT 10
);

const TagsQuery = zql.Query(
    \\SELECT tag, COUNT(*) as count
    \\FROM document_tags
    \\GROUP BY tag
    \\ORDER BY count DESC
    \\LIMIT 100
);

pub fn search(alloc: Allocator, query: []const u8, tag_filter: ?[]const u8) ![]const u8 {
    var c = &(client orelse return error.NotInitialized);

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
    else
        c.query(DocsByFts.positional, DocsByFts.bind(.{ .query = fts_query })) catch null;

    if (doc_result) |*res| {
        defer res.deinit();
        for (res.rows) |row| try jw.write(Doc.fromRow(row).toJson());
    }

    // publications are excluded when filtering by tag (tags only apply to documents)
    if (tag_filter == null) {
        var pub_result = c.query(
            PubSearch.positional,
            PubSearch.bind(.{ .query = fts_query }),
        ) catch null;

        if (pub_result) |*res| {
            defer res.deinit();
            for (res.rows) |row| try jw.write(Pub.fromRow(row).toJson());
        }
    }

    try jw.endArray();
    return try output.toOwnedSlice();
}

pub fn getTags(alloc: Allocator) ![]const u8 {
    var c = &(client orelse return error.NotInitialized);

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var res = c.query(TagsQuery.positional, &.{}) catch {
        try output.writer.writeAll("{\"error\":\"failed to fetch tags\"}");
        return try output.toOwnedSlice();
    };
    defer res.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (res.rows) |row| try jw.write(TagJson{ .tag = row.text(0), .count = row.int(1) });
    try jw.endArray();
    return try output.toOwnedSlice();
}

pub fn getStats() struct { documents: i64, publications: i64, searches: i64, errors: i64, started_at: i64 } {
    var c = &(client orelse return .{ .documents = 0, .publications = 0, .searches = 0, .errors = 0, .started_at = 0 });

    var res = c.query(
        \\SELECT
        \\  (SELECT COUNT(*) FROM documents) as docs,
        \\  (SELECT COUNT(*) FROM publications) as pubs,
        \\  (SELECT total_searches FROM stats WHERE id = 1) as searches,
        \\  (SELECT total_errors FROM stats WHERE id = 1) as errors,
        \\  (SELECT service_started_at FROM stats WHERE id = 1) as started_at
    , &.{}) catch return .{ .documents = 0, .publications = 0, .searches = 0, .errors = 0, .started_at = 0 };
    defer res.deinit();

    const row = res.first() orelse return .{ .documents = 0, .publications = 0, .searches = 0, .errors = 0, .started_at = 0 };
    return .{ .documents = row.int(0), .publications = row.int(1), .searches = row.int(2), .errors = row.int(3), .started_at = row.int(4) };
}

pub fn recordSearch(query: []const u8) void {
    recordActivity();
    var c = &(client orelse return);
    c.exec("UPDATE stats SET total_searches = total_searches + 1 WHERE id = 1", &.{}) catch {};

    // track popular searches (skip empty/very short queries)
    if (query.len >= 2) {
        c.exec(
            "INSERT INTO popular_searches (query, count) VALUES (?, 1) ON CONFLICT(query) DO UPDATE SET count = count + 1",
            &.{query},
        ) catch {};
    }
}

pub fn recordError() void {
    var c = &(client orelse return);
    c.exec("UPDATE stats SET total_errors = total_errors + 1 WHERE id = 1", &.{}) catch {};
}

pub fn getPopular(alloc: Allocator, limit: usize) ![]const u8 {
    var c = &(client orelse return error.NotInitialized);

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var buf: [8]u8 = undefined;
    const limit_str = std.fmt.bufPrint(&buf, "{d}", .{limit}) catch "3";

    var res = c.query(
        "SELECT query, count FROM popular_searches ORDER BY count DESC LIMIT ?",
        &.{limit_str},
    ) catch {
        try output.writer.writeAll("[]");
        return try output.toOwnedSlice();
    };
    defer res.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (res.rows) |row| try jw.write(PopularJson{ .query = row.text(0), .count = row.int(1) });
    try jw.endArray();
    return try output.toOwnedSlice();
}

/// Build FTS5 query with OR between terms: "cat dog" -> "cat OR dog*"
/// Uses OR for better recall with BM25 ranking (more matches = higher score)
fn buildFtsQuery(alloc: Allocator, query: []const u8) ![]const u8 {
    if (query.len == 0) return "";

    // normalize: trim whitespace
    var start: usize = 0;
    var end: usize = query.len;
    while (start < end and query[start] == ' ') start += 1;
    while (end > start and query[end - 1] == ' ') end -= 1;
    if (start >= end) return "";

    const trimmed = query[start..end];

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

/// Find documents similar to a given document using vector similarity
pub fn findSimilar(alloc: Allocator, uri: []const u8, limit: usize) ![]const u8 {
    var c = &(client orelse return error.NotInitialized);

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var limit_buf: [8]u8 = undefined;
    const limit_str = std.fmt.bufPrint(&limit_buf, "{d}", .{limit + 1}) catch "6"; // +1 to exclude self

    // vector similarity search using the document's embedding
    // note: CAST required because Hrana sends all values as text
    var res = c.query(
        \\SELECT d.uri, d.did, d.title, '' as snippet,
        \\  d.created_at, d.rkey, COALESCE(p.base_path, '') as base_path,
        \\  CASE WHEN d.publication_uri != '' THEN 1 ELSE 0 END as has_publication
        \\FROM vector_top_k('documents_embedding_idx',
        \\  (SELECT embedding FROM documents WHERE uri = ?), CAST(? AS INTEGER)) AS v
        \\JOIN documents d ON d.rowid = v.id
        \\LEFT JOIN publications p ON d.publication_uri = p.uri
        \\WHERE d.uri != ?
    , &.{ uri, limit_str, uri }) catch {
        try output.writer.writeAll("[]");
        return try output.toOwnedSlice();
    };
    defer res.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();
    for (res.rows) |row| try jw.write(Doc.fromRow(row).toJson());
    try jw.endArray();
    return try output.toOwnedSlice();
}
