const std = @import("std");
const db = @import("db/mod.zig");

pub fn insertDocument(
    uri: []const u8,
    did: []const u8,
    rkey: []const u8,
    title: []const u8,
    content: []const u8,
    created_at: ?[]const u8,
    publication_uri: ?[]const u8,
    tags: []const []const u8,
    platform: []const u8,
    source_collection: []const u8,
    path: ?[]const u8,
) !void {
    const c = db.getClient() orelse return error.NotInitialized;

    // dedupe: if (did, rkey) exists with different uri, clean up old record first
    // this handles cross-collection duplicates (e.g., pub.leaflet.document + site.standard.document)
    if (c.query("SELECT uri FROM documents WHERE did = ? AND rkey = ?", &.{ did, rkey })) |result_val| {
        var result = result_val;
        defer result.deinit();
        if (result.first()) |row| {
            const old_uri = row.text(0);
            if (!std.mem.eql(u8, old_uri, uri)) {
                c.exec("DELETE FROM documents_fts WHERE uri = ?", &.{old_uri}) catch {};
                c.exec("DELETE FROM document_tags WHERE document_uri = ?", &.{old_uri}) catch {};
                c.exec("DELETE FROM documents WHERE uri = ?", &.{old_uri}) catch {};
            }
        }
    } else |_| {}

    // compute denormalized fields
    const pub_uri = publication_uri orelse "";
    const has_pub: []const u8 = if (pub_uri.len > 0) "1" else "0";

    // look up base_path from publication (or fallback to DID lookup)
    var base_path: []const u8 = "";
    if (pub_uri.len > 0) {
        if (c.query("SELECT base_path FROM publications WHERE uri = ?", &.{pub_uri})) |res| {
            var result = res;
            defer result.deinit();
            if (result.first()) |row| {
                base_path = row.text(0);
            }
        } else |_| {}
    }
    // fallback: find any publication by this DID
    if (base_path.len == 0) {
        if (c.query("SELECT base_path FROM publications WHERE did = ? LIMIT 1", &.{did})) |res| {
            var result = res;
            defer result.deinit();
            if (result.first()) |row| {
                base_path = row.text(0);
            }
        } else |_| {}
    }

    // detect platform from base_path (overrides collection-based detection for site.standard.*)
    var actual_platform = platform;
    if (std.mem.eql(u8, platform, "standardsite") or std.mem.eql(u8, platform, "unknown")) {
        if (std.mem.indexOf(u8, base_path, "offprint.app") != null or
            std.mem.indexOf(u8, base_path, "offprint.test") != null)
        {
            actual_platform = "offprint";
        } else if (std.mem.indexOf(u8, base_path, "pckt.blog") != null) {
            actual_platform = "pckt";
        } else if (std.mem.indexOf(u8, base_path, "leaflet.pub") != null) {
            actual_platform = "leaflet";
        }
    }

    try c.exec(
        "INSERT OR REPLACE INTO documents (uri, did, rkey, title, content, created_at, publication_uri, platform, source_collection, path, base_path, has_publication) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        &.{ uri, did, rkey, title, content, created_at orelse "", pub_uri, actual_platform, source_collection, path orelse "", base_path, has_pub },
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
    const c = db.getClient() orelse return error.NotInitialized;

    // dedupe: if (did, rkey) exists with different uri, clean up old record first
    if (c.query("SELECT uri FROM publications WHERE did = ? AND rkey = ?", &.{ did, rkey })) |result_val| {
        var result = result_val;
        defer result.deinit();
        if (result.first()) |row| {
            const old_uri = row.text(0);
            if (!std.mem.eql(u8, old_uri, uri)) {
                c.exec("DELETE FROM publications_fts WHERE uri = ?", &.{old_uri}) catch {};
                c.exec("DELETE FROM publications WHERE uri = ?", &.{old_uri}) catch {};
            }
        }
    } else |_| {}

    try c.exec(
        "INSERT OR REPLACE INTO publications (uri, did, rkey, name, description, base_path) VALUES (?, ?, ?, ?, ?, ?)",
        &.{ uri, did, rkey, name, description orelse "", base_path orelse "" },
    );

    // update FTS index (includes base_path for subdomain search)
    c.exec("DELETE FROM publications_fts WHERE uri = ?", &.{uri}) catch {};
    c.exec(
        "INSERT INTO publications_fts (uri, name, description, base_path) VALUES (?, ?, ?, ?)",
        &.{ uri, name, description orelse "", base_path orelse "" },
    ) catch {};
}

pub fn deleteDocument(uri: []const u8) void {
    const c = db.getClient() orelse return;

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
    const c = db.getClient() orelse return;

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
