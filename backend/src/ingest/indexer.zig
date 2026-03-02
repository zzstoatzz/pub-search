const std = @import("std");
const logfire = @import("logfire");
const db = @import("../db/mod.zig");

/// Hash title+content for cross-platform dedup.
/// Returns a 16-char hex string (wyhash of "title\x00content").
fn computeContentHash(title: []const u8, content: []const u8) [16]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(title);
    hasher.update("\x00");
    hasher.update(content);
    const hash = hasher.final();
    return std.fmt.bytesToHex(std.mem.asBytes(&hash), .lower);
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
    platform: []const u8,
    source_collection: []const u8,
    path: ?[]const u8,
    content_type: ?[]const u8,
    cover_image: ?[]const u8,
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

    // cross-platform content dedup: if same author already has a document with
    // identical title+content (different rkey from a different platform), skip it.
    const content_hash: [16]u8 = computeContentHash(title, content);
    if (c.query("SELECT uri FROM documents WHERE did = ? AND content_hash = ?", &.{ did, &content_hash })) |res| {
        var result = res;
        defer result.deinit();
        if (result.first()) |row| {
            const existing_uri = row.text(0);
            if (!std.mem.eql(u8, existing_uri, uri)) {
                logfire.debug("indexer: skipping dupe for {s} (existing: {s})", .{ uri, existing_uri });
                return;
            }
        }
    } else |_| {}

    // compute denormalized fields
    const pub_uri = publication_uri orelse "";
    const has_pub: []const u8 = if (pub_uri.len > 0) "1" else "0";

    // look up base_path from publication (or fallback to DID lookup)
    // use a stack buffer because row.text() returns a slice into result memory
    // which gets freed by result.deinit()
    var base_path_buf: [256]u8 = undefined;
    var base_path: []const u8 = "";

    if (pub_uri.len > 0) {
        if (c.query("SELECT base_path FROM publications WHERE uri = ?", &.{pub_uri})) |res| {
            var result = res;
            defer result.deinit();
            if (result.first()) |row| {
                const val = row.text(0);
                if (val.len > 0 and val.len <= base_path_buf.len) {
                    @memcpy(base_path_buf[0..val.len], val);
                    base_path = base_path_buf[0..val.len];
                }
            }
        } else |_| {}
    }
    // fallback: find publication by DID, preferring platform-specific matches
    if (base_path.len == 0) {
        // try platform-specific publication first
        const platform_pattern: []const u8 = if (std.mem.eql(u8, platform, "greengale"))
            "%greengale.app%"
        else if (std.mem.eql(u8, platform, "pckt"))
            "%pckt.blog%"
        else if (std.mem.eql(u8, platform, "offprint"))
            "%offprint.app%"
        else if (std.mem.eql(u8, platform, "leaflet"))
            "%leaflet.pub%"
        else
            "%";

        if (c.query("SELECT base_path FROM publications WHERE did = ? AND base_path LIKE ? ORDER BY LENGTH(base_path) DESC LIMIT 1", &.{ did, platform_pattern })) |res| {
            var result = res;
            defer result.deinit();
            if (result.first()) |row| {
                const val = row.text(0);
                if (val.len > 0 and val.len <= base_path_buf.len) {
                    @memcpy(base_path_buf[0..val.len], val);
                    base_path = base_path_buf[0..val.len];
                }
            }
        } else |_| {}

        // if no platform-specific match, fall back to any publication
        if (base_path.len == 0) {
            if (c.query("SELECT base_path FROM publications WHERE did = ? ORDER BY LENGTH(base_path) DESC LIMIT 1", &.{did})) |res| {
                var result = res;
                defer result.deinit();
                if (result.first()) |row| {
                    const val = row.text(0);
                    if (val.len > 0 and val.len <= base_path_buf.len) {
                        @memcpy(base_path_buf[0..val.len], val);
                        base_path = base_path_buf[0..val.len];
                    }
                }
            } else |_| {}
        }
    }

    // fallback: if publication_uri is an HTTP(S) URL, use its host as base_path
    // standard.site documents store the origin URL in the "site" field, which
    // our extractor reads into publication_uri. Strip the scheme to match
    // base_path convention (frontend prepends "https://").
    if (base_path.len == 0 and pub_uri.len > 0) {
        var host = if (std.mem.startsWith(u8, pub_uri, "https://"))
            pub_uri["https://".len..]
        else if (std.mem.startsWith(u8, pub_uri, "http://"))
            pub_uri["http://".len..]
        else
            @as([]const u8, "");
        // strip trailing slash to avoid double-slash when combined with path
        if (host.len > 1 and host[host.len - 1] == '/')
            host = host[0 .. host.len - 1];
        if (host.len > 0 and host.len <= base_path_buf.len) {
            @memcpy(base_path_buf[0..host.len], host);
            base_path = base_path_buf[0..host.len];
        }
    }

    // normalize: strip trailing slash to avoid double-slash in URLs
    if (base_path.len > 1 and base_path[base_path.len - 1] == '/')
        base_path = base_path[0 .. base_path.len - 1];

    // skip .test domains (dev/staging data)
    if (std.mem.endsWith(u8, base_path, ".test")) return;

    // detect platform from basePath if platform is unknown/other
    // this handles site.standard.* documents where collection doesn't indicate platform
    var actual_platform = platform;
    if (std.mem.eql(u8, platform, "unknown") or std.mem.eql(u8, platform, "other")) {
        if (std.mem.indexOf(u8, base_path, "leaflet.pub") != null) {
            actual_platform = "leaflet";
        } else if (std.mem.indexOf(u8, base_path, "pckt.blog") != null) {
            actual_platform = "pckt";
        } else if (std.mem.indexOf(u8, base_path, "offprint.app") != null) {
            actual_platform = "offprint";
        } else if (std.mem.indexOf(u8, base_path, "greengale.app") != null) {
            actual_platform = "greengale";
        } else if (content_type) |ct| {
            // fallback: detect platform from content.$type for custom domains
            // e.g., "pub.leaflet.content" indicates leaflet even with custom domain
            if (std.mem.startsWith(u8, ct, "pub.leaflet.")) {
                actual_platform = "leaflet";
            }
        }
    }

    // use ON CONFLICT to preserve embedded_at (INSERT OR REPLACE would nuke it)
    // indexed_at uses strftime to record when this row was inserted/updated in Turso
    // (created_at is the document's publication date, which can be old for resynced docs)
    try c.exec(
        \\INSERT INTO documents (uri, did, rkey, title, content, created_at, publication_uri, platform, source_collection, path, base_path, has_publication, content_hash, cover_image, indexed_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%S', 'now'))
        \\ON CONFLICT(uri) DO UPDATE SET
        \\  did = excluded.did,
        \\  rkey = excluded.rkey,
        \\  title = excluded.title,
        \\  content = excluded.content,
        \\  created_at = excluded.created_at,
        \\  publication_uri = excluded.publication_uri,
        \\  platform = excluded.platform,
        \\  source_collection = excluded.source_collection,
        \\  path = excluded.path,
        \\  base_path = excluded.base_path,
        \\  has_publication = excluded.has_publication,
        \\  content_hash = excluded.content_hash,
        \\  cover_image = excluded.cover_image,
        \\  indexed_at = strftime('%Y-%m-%dT%H:%M:%S', 'now'),
        \\  embedded_at = documents.embedded_at
    ,
        &.{ uri, did, rkey, title, content, created_at orelse "", pub_uri, actual_platform, source_collection, path orelse "", base_path, has_pub, &content_hash, cover_image orelse "" },
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
