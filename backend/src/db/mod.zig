const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

const zql = @import("zql");
const turso = @import("turso.zig");
const schema = @import("schema.zig");
const result = @import("result.zig");

pub const Client = turso.Client;
pub const Result = turso.Result;
pub const Row = turso.Row;

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var client: ?turso.Client = null;

pub fn init() !void {
    client = try turso.Client.init(gpa.allocator());
    try schema.init(&client.?);
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
    c.exec("DELETE FROM documents WHERE uri = ?", &.{uri}) catch {};
    c.exec("DELETE FROM documents_fts WHERE uri = ?", &.{uri}) catch {};
    c.exec("DELETE FROM document_tags WHERE document_uri = ?", &.{uri}) catch {};
}

pub fn deletePublication(uri: []const u8) void {
    var c = &(client orelse return);
    c.exec("DELETE FROM publications WHERE uri = ?", &.{uri}) catch {};
    c.exec("DELETE FROM publications_fts WHERE uri = ?", &.{uri}) catch {};
}

const Doc = struct {
    uri: []const u8,
    did: []const u8,
    title: []const u8,
    snippet: []const u8,
    created_at: []const u8,
    rkey: []const u8,
    base_path: []const u8,
    has_publication: bool,

    fn fromRow(row: Row) Doc {
        return .{
            .uri = row.text(0),
            .did = row.text(1),
            .title = row.text(2),
            .snippet = row.text(3),
            .created_at = row.text(4),
            .rkey = row.text(5),
            .base_path = row.text(6),
            .has_publication = row.int(7) != 0,
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
    \\  snippet(documents_fts, 2, '<mark>', '</mark>', '...', 32) as snippet,
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
    \\  snippet(documents_fts, 2, '<mark>', '</mark>', '...', 32) as snippet,
    \\  d.created_at, d.rkey, p.base_path,
    \\  CASE WHEN d.publication_uri != '' THEN 1 ELSE 0 END as has_publication
    \\FROM documents_fts f
    \\JOIN documents d ON f.uri = d.uri
    \\LEFT JOIN publications p ON d.publication_uri = p.uri
    \\WHERE documents_fts MATCH :query
    \\ORDER BY rank LIMIT 40
);

const Pub = struct {
    uri: []const u8,
    did: []const u8,
    name: []const u8,
    snippet: []const u8,
    rkey: []const u8,
    base_path: []const u8,

    fn fromRow(row: Row) Pub {
        return .{
            .uri = row.text(0),
            .did = row.text(1),
            .name = row.text(2),
            .snippet = row.text(3),
            .rkey = row.text(4),
            .base_path = row.text(5),
        };
    }
};

const PubSearch = zql.Query(
    \\SELECT f.uri, p.did, p.name,
    \\  snippet(publications_fts, 2, '<mark>', '</mark>', '...', 32) as snippet,
    \\  p.rkey, p.base_path
    \\FROM publications_fts f
    \\JOIN publications p ON f.uri = p.uri
    \\WHERE publications_fts MATCH :query
    \\ORDER BY rank LIMIT 10
);

const TagCount = struct {
    tag: []const u8,
    count: i64,

    fn fromRow(row: Row) TagCount {
        return .{ .tag = row.text(0), .count = row.int(1) };
    }
};

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
        for (res.rows) |row| {
            const doc = Doc.fromRow(row);
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write(if (doc.has_publication) "article" else "looseleaf");
            try jw.objectField("uri");
            try jw.write(doc.uri);
            try jw.objectField("did");
            try jw.write(doc.did);
            try jw.objectField("title");
            try jw.write(doc.title);
            try jw.objectField("snippet");
            try jw.write(doc.snippet);
            try jw.objectField("createdAt");
            try jw.write(doc.created_at);
            try jw.objectField("rkey");
            try jw.write(doc.rkey);
            try jw.objectField("basePath");
            try jw.write(doc.base_path);
            try jw.endObject();
        }
    }

    // search publications (only if no tag filter)
    if (tag_filter == null) {
        var pub_result = c.query(
            PubSearch.positional,
            PubSearch.bind(.{ .query = fts_query }),
        ) catch null;

        if (pub_result) |*res| {
            defer res.deinit();
            for (res.rows) |row| {
                const p = Pub.fromRow(row);
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("publication");
                try jw.objectField("uri");
                try jw.write(p.uri);
                try jw.objectField("did");
                try jw.write(p.did);
                try jw.objectField("title");
                try jw.write(p.name);
                try jw.objectField("snippet");
                try jw.write(p.snippet);
                try jw.objectField("rkey");
                try jw.write(p.rkey);
                try jw.objectField("basePath");
                try jw.write(p.base_path);
                try jw.endObject();
            }
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
        try output.writer.writeAll("[]");
        return try output.toOwnedSlice();
    };
    defer res.deinit();

    var jw: json.Stringify = .{ .writer = &output.writer };
    try jw.beginArray();

    for (res.rows) |row| {
        const tag = TagCount.fromRow(row);
        try jw.beginObject();
        try jw.objectField("tag");
        try jw.write(tag.tag);
        try jw.objectField("count");
        try jw.write(tag.count);
        try jw.endObject();
    }

    try jw.endArray();
    return try output.toOwnedSlice();
}

pub fn getStats() struct { documents: i64, publications: i64 } {
    var c = &(client orelse return .{ .documents = 0, .publications = 0 });

    var res = c.query(
        \\SELECT
        \\  (SELECT COUNT(*) FROM documents) as docs,
        \\  (SELECT COUNT(*) FROM publications) as pubs
    , &.{}) catch return .{ .documents = 0, .publications = 0 };
    defer res.deinit();

    const row = res.first() orelse return .{ .documents = 0, .publications = 0 };
    return .{ .documents = row.int(0), .publications = row.int(1) };
}

/// Build FTS5 query with prefix matching: "cat dog" -> "cat* dog*"
fn buildFtsQuery(alloc: Allocator, query: []const u8) ![]const u8 {
    if (query.len == 0) return "";

    // normalize dots to spaces
    const normalized = try alloc.dupe(u8, query);
    for (normalized) |*c| {
        if (c.* == '.') c.* = ' ';
    }

    // count words
    var word_count: usize = 0;
    var in_word = false;
    for (normalized) |c| {
        if (c == ' ') {
            in_word = false;
        } else if (!in_word) {
            word_count += 1;
            in_word = true;
        }
    }

    if (word_count == 0) return "";

    // allocate: original length + one '*' per word
    const buf = try alloc.alloc(u8, normalized.len + word_count);
    var pos: usize = 0;
    in_word = false;

    for (normalized) |c| {
        if (c == ' ') {
            if (in_word) {
                buf[pos] = '*';
                pos += 1;
                in_word = false;
            }
            buf[pos] = ' ';
            pos += 1;
        } else {
            buf[pos] = c;
            pos += 1;
            in_word = true;
        }
    }

    if (in_word) {
        buf[pos] = '*';
        pos += 1;
    }

    return buf[0..pos];
}
