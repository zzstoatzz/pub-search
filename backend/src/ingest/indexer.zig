const std = @import("std");
const Io = std.Io;
const logfire = @import("logfire");
const db = @import("../db.zig");

fn isHttpUrl(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "https://") or std.mem.startsWith(u8, s, "http://");
}

/// If `url` is an HTTP(S) URL pointing at a site ROOT (no path after the host,
/// or just "/"), return its host. A standard.site document stores its canonical
/// home in the `site` field; a bare root there is the publication's own domain
/// (e.g. "https://blog.mainasara.dev" → "blog.mainasara.dev") and should win over
/// a same-author publication guessed by DID. A `site` carrying a path (e.g.
/// leaflet's "https://leaflet.pub/p/<did>") is a deep link, not a base host, so
/// this returns null and the DID lookup finds the real subdomain pub instead.
fn httpSiteRootHost(url: []const u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, url, "https://"))
        url["https://".len..]
    else if (std.mem.startsWith(u8, url, "http://"))
        url["http://".len..]
    else
        return null;
    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const host = if (slash) |i| rest[0..i] else rest;
    if (host.len == 0) return null;
    // only a root: nothing after the host, or just a trailing "/"
    if (slash) |i| {
        if (rest.len - i > 1) return null;
    }
    return host;
}

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

    // banned bulk-archive repos (purged 2026-06-10): second gate behind the
    // ingester's ban — nothing reinserts these, not even replays or backfills.
    if (std.mem.eql(u8, did, "did:plc:oql6ds5vnff4ugar6rruliwd")) {
        logfire.span("tap.dropped", .{ .reason = "banned_did", .uri = uri }).end();
        return;
    }

    // dedupe: if (did, rkey) exists with different uri, clean up old record first
    // this handles cross-collection duplicates (e.g., pub.leaflet.document + site.standard.document)
    var doc_exists = false;
    if (c.query("SELECT uri FROM documents WHERE did = ? AND rkey = ?", &.{ did, rkey })) |result_val| {
        var result = result_val;
        defer result.deinit();
        if (result.first()) |row| {
            const old_uri = row.text(0);
            if (!std.mem.eql(u8, old_uri, uri)) {
                c.exec("DELETE FROM documents_fts WHERE uri = ?", &.{old_uri}) catch {};
                c.exec("DELETE FROM document_tags WHERE document_uri = ?", &.{old_uri}) catch {};
                c.exec("DELETE FROM documents WHERE uri = ?", &.{old_uri}) catch {};
            } else {
                doc_exists = true;
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
                logfire.span("tap.dropped", .{ .reason = "content_hash_dupe", .uri = uri, .existing_uri = existing_uri }).end();
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
    // prefer the document's own `site` root host (read into publication_uri) over
    // a DID-guessed publication. authors can run BOTH a known-platform publication
    // and a standard.site custom-domain blog; without this, the DID fallback below
    // glues the custom-domain doc onto the unrelated platform pub and emits a dead
    // link (e.g. neutrino2211.leaflet.pub/... 404 vs blog.mainasara.dev/... 200).
    if (base_path.len == 0 and isHttpUrl(pub_uri)) {
        if (httpSiteRootHost(pub_uri)) |host| {
            if (host.len <= base_path_buf.len) {
                @memcpy(base_path_buf[0..host.len], host);
                base_path = base_path_buf[0..host.len];
            }
        }
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
    if (std.mem.endsWith(u8, base_path, ".test")) {
        logfire.span("tap.dropped", .{ .reason = "test_domain", .uri = uri, .base_path = base_path }).end();
        return;
    }

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

    // bridgy fed is classified authoritatively by the reconciler, which resolves
    // the DID's PDS and marks docs hosted on brid.gy. We can't cheaply resolve the
    // PDS here without blocking the firehose worker, so default to "0" at ingest.
    // (The old "platform==other && HTTP site field ⇒ bridgy fed" heuristic was
    // wrong — legit standard.site custom-domain blogs also put an HTTP URL in the
    // `site` field, so it dropped real content like blog.mainasara.dev.)
    const is_bridgyfed: []const u8 = "0";

    // use ON CONFLICT to preserve embedded_at (INSERT OR REPLACE would nuke it)
    // indexed_at uses strftime to record when this row was inserted/updated in Turso
    // (created_at is the document's publication date, which can be old for resynced docs)
    try c.exec(
        \\INSERT INTO documents (uri, did, rkey, title, content, created_at, publication_uri, platform, source_collection, path, base_path, has_publication, content_hash, cover_image, indexed_at, is_bridgyfed, content_type)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%S', 'now'), ?, ?)
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
        \\  is_bridgyfed = excluded.is_bridgyfed,
        \\  content_type = excluded.content_type,
        \\  embedded_at = documents.embedded_at
    ,
        &.{ uri, did, rkey, title, content, created_at orelse "", pub_uri, actual_platform, source_collection, path orelse "", base_path, has_pub, &content_hash, cover_image orelse "", is_bridgyfed, content_type orelse "" },
    );

    // update FTS index. `uri` is UNINDEXED in documents_fts, so this DELETE
    // full-scans the whole FTS table on remote turso (~16s at 42k docs) — it
    // was silently the entire indexing budget. Only pay it when this uri
    // actually has a row to replace; creates (the vast majority) skip it.
    if (doc_exists) {
        c.exec("DELETE FROM documents_fts WHERE uri = ?", &.{uri}) catch {};
    }
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

    // banned bulk-archive repos (purged 2026-06-10): second gate behind the
    // ingester's ban — nothing reinserts these, not even replays or backfills.
    if (std.mem.eql(u8, did, "did:plc:oql6ds5vnff4ugar6rruliwd")) {
        logfire.span("tap.dropped", .{ .reason = "banned_did", .uri = uri }).end();
        return;
    }

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
        \\INSERT INTO publications (uri, did, rkey, name, description, base_path, indexed_at)
        \\VALUES (?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%S', 'now'))
        \\ON CONFLICT(uri) DO UPDATE SET
        \\  did = excluded.did,
        \\  rkey = excluded.rkey,
        \\  name = excluded.name,
        \\  description = excluded.description,
        \\  base_path = excluded.base_path,
        \\  indexed_at = strftime('%Y-%m-%dT%H:%M:%S', 'now')
    ,
        &.{ uri, did, rkey, name, description orelse "", base_path orelse "" },
    );

    // backfill: update documents whose base_path is empty or stale (differs from publication)
    if (base_path) |bp| {
        if (bp.len > 0) {
            c.exec(
                \\UPDATE documents SET
                \\  base_path = ?,
                \\  indexed_at = strftime('%Y-%m-%dT%H:%M:%S', 'now'),
                \\  embedded_at = NULL
                \\WHERE publication_uri = ?
                \\  AND (base_path IS NULL OR base_path = '' OR base_path != ?)
            , &.{ bp, uri, bp }) catch |err| {
                logfire.warn("indexer: base_path backfill failed for pub {s}: {}", .{ uri, err });
            };
        }
    }

    // update FTS index (includes base_path for subdomain search)
    c.exec("DELETE FROM publications_fts WHERE uri = ?", &.{uri}) catch {};
    c.exec(
        "INSERT INTO publications_fts (uri, name, description, base_path) VALUES (?, ?, ?, ?)",
        &.{ uri, name, description orelse "", base_path orelse "" },
    ) catch {};
}

fn currentTimestamp(io: Io) i64 {
    return @intCast(@divFloor(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
}

pub fn deleteDocument(uri: []const u8) void {
    const c = db.getClient() orelse return;

    // record tombstone
    var ts_buf: [20]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{currentTimestamp(c.io)}) catch "0";
    c.exec(
        "INSERT OR REPLACE INTO tombstones (uri, record_type, deleted_at) VALUES (?, 'document', ?)",
        &.{ uri, ts },
    ) catch {};
    // delete record
    c.exec("DELETE FROM documents WHERE uri = ?", &.{uri}) catch {};
    c.exec("DELETE FROM documents_fts WHERE uri = ?", &.{uri}) catch {};
    c.exec("DELETE FROM document_tags WHERE document_uri = ?", &.{uri}) catch {};
}

pub fn insertRecommend(
    uri: []const u8,
    did: []const u8,
    rkey: []const u8,
    document_uri: []const u8,
    created_at: ?[]const u8,
) !void {
    const c = db.getClient() orelse return error.NotInitialized;

    try c.exec(
        \\INSERT INTO recommends (uri, did, rkey, document_uri, created_at, indexed_at)
        \\VALUES (?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%S', 'now'))
        \\ON CONFLICT(uri) DO UPDATE SET
        \\  did = excluded.did,
        \\  rkey = excluded.rkey,
        \\  document_uri = excluded.document_uri,
        \\  created_at = excluded.created_at,
        \\  indexed_at = strftime('%Y-%m-%dT%H:%M:%S', 'now')
    ,
        &.{ uri, did, rkey, document_uri, created_at orelse "" },
    );
}

pub fn deleteRecommend(uri: []const u8) void {
    const c = db.getClient() orelse return;

    // record tombstone
    var ts_buf: [20]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{currentTimestamp(c.io)}) catch "0";
    c.exec(
        "INSERT OR REPLACE INTO tombstones (uri, record_type, deleted_at) VALUES (?, 'recommend', ?)",
        &.{ uri, ts },
    ) catch {};
    c.exec("DELETE FROM recommends WHERE uri = ?", &.{uri}) catch {};
}

pub fn deletePublication(uri: []const u8) void {
    const c = db.getClient() orelse return;

    // record tombstone
    var ts_buf: [20]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{currentTimestamp(c.io)}) catch "0";
    c.exec(
        "INSERT OR REPLACE INTO tombstones (uri, record_type, deleted_at) VALUES (?, 'publication', ?)",
        &.{ uri, ts },
    ) catch {};
    // delete record
    c.exec("DELETE FROM publications WHERE uri = ?", &.{uri}) catch {};
    c.exec("DELETE FROM publications_fts WHERE uri = ?", &.{uri}) catch {};
}

test "httpSiteRootHost: root URL → host, deep link → null" {
    const t = std.testing;
    // bare root: the publication's own domain → use it
    try t.expectEqualStrings("blog.mainasara.dev", httpSiteRootHost("https://blog.mainasara.dev").?);
    try t.expectEqualStrings("blog.mainasara.dev", httpSiteRootHost("https://blog.mainasara.dev/").?);
    try t.expectEqualStrings("piffey.net", httpSiteRootHost("https://piffey.net").?);
    // deep link (leaflet's generic site field) → not a base host
    try t.expect(httpSiteRootHost("https://leaflet.pub/p/did:plc:abc") == null);
    try t.expect(httpSiteRootHost("https://example.com/posts/x") == null);
    // not http
    try t.expect(httpSiteRootHost("at://did:plc:abc/foo") == null);
}
