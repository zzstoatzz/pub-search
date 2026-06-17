//! Sync from Turso to local SQLite
//! Full sync on startup, incremental sync periodically

const std = @import("std");
const Io = std.Io;
const zqlite = @import("zqlite");
const logfire = @import("logfire");
const Allocator = std.mem.Allocator;
const Client = @import("Client.zig");
const LocalDb = @import("LocalDb.zig");
const policy = @import("../policy.zig");

const BATCH_SIZE = 500;

/// Full sync: fetch all data from Turso and populate local SQLite.
/// Uses INSERT OR REPLACE so existing data stays queryable during sync.
/// Only marks not-ready on first-ever sync (empty DB).
pub fn fullSync(turso: *Client, local: *LocalDb) !void {
    std.debug.print("sync: starting full sync...\n", .{});

    const conn = local.getConn() orelse return error.LocalNotOpen;

    // check if we have existing data — if so, keep serving while syncing
    const has_data = blk: {
        local.lock();
        defer local.unlock();
        const row = conn.row("SELECT COUNT(*) FROM documents", .{}) catch break :blk false;
        if (row) |r| {
            defer r.deinit();
            break :blk r.int(0) > 0;
        }
        break :blk false;
    };

    if (!has_data) {
        // first-ever sync: nothing to serve, mark not-ready
        local.setReady(false);

        // clear tables for clean initial sync
        local.lock();
        defer local.unlock();
        conn.exec("DELETE FROM documents_fts", .{}) catch {};
        conn.exec("DELETE FROM documents", .{}) catch {};
        conn.exec("DELETE FROM publications_fts", .{}) catch {};
        conn.exec("DELETE FROM publications", .{}) catch {};
        conn.exec("DELETE FROM document_tags", .{}) catch {};
    } else {
        // re-sync: keep serving existing data while we refresh in-place
        // INSERT OR REPLACE will update rows; stale data is acceptable
        local.setReady(true);
        std.debug.print("sync: local has data, keeping ready during re-sync\n", .{});
    }

    // create temp table to track synced URIs (for stale-doc cleanup)
    {
        local.lock();
        defer local.unlock();
        conn.exec("DROP TABLE IF EXISTS _synced_uris", .{}) catch {};
        conn.exec("CREATE TEMP TABLE _synced_uris (uri TEXT PRIMARY KEY)", .{}) catch {};
    }

    // sync documents in batches — fetch from Turso unlocked, write to local with brief lock
    var doc_count: usize = 0;
    var offset: usize = 0;
    while (true) {
        var offset_buf: [16]u8 = undefined;
        const offset_str = std.fmt.bufPrint(&offset_buf, "{d}", .{offset}) catch break;

        // fetch from Turso (no lock held — search can use local DB)
        var result = turso.query(
            \\SELECT uri, did, rkey, title, content, created_at, publication_uri,
            \\  platform, source_collection, path, base_path, has_publication, indexed_at, embedded_at,
            \\  COALESCE(cover_image, '') as cover_image, COALESCE(is_bridgyfed, 0) as is_bridgyfed,
            \\  COALESCE(url_dead, 0) as url_dead
            \\FROM documents
            \\ORDER BY uri
            \\LIMIT 500 OFFSET ?
        , &.{offset_str}) catch |err| {
            logfire.warn("sync: turso query failed: {}", .{err});
            break;
        };
        defer result.deinit();

        if (result.rows.len == 0) break;

        // write batch to local (brief lock)
        {
            local.lock();
            defer local.unlock();
            conn.exec("BEGIN", .{}) catch {};
            for (result.rows) |row| {
                insertDocumentLocal(conn, row) catch |err| {
                    logfire.warn("sync: insert doc failed: {}", .{err});
                };
                conn.exec("INSERT OR IGNORE INTO _synced_uris (uri) VALUES (?)", .{row.text(0)}) catch {};
                doc_count += 1;
            }
            conn.exec("COMMIT", .{}) catch {};
        }

        offset += result.rows.len;
        if (offset % 1000 == 0) {
            std.debug.print("sync: synced {d} documents...\n", .{offset});
        }
    }

    // sync publications (fetch unlocked, write with brief lock)
    var pub_count: usize = 0;
    {
        var pub_result = turso.query(
            "SELECT uri, did, rkey, name, description, base_path, platform, indexed_at FROM publications",
            &.{},
        ) catch |err| {
            logfire.warn("sync: turso publications query failed: {}", .{err});
            return;
        };
        defer pub_result.deinit();

        local.lock();
        defer local.unlock();
        conn.exec("BEGIN", .{}) catch {};
        for (pub_result.rows) |row| {
            insertPublicationLocal(conn, row) catch |err| {
                logfire.warn("sync: insert pub failed: {}", .{err});
            };
            pub_count += 1;
        }
        conn.exec("COMMIT", .{}) catch {};
    }

    // sync tags
    var tag_count: usize = 0;
    {
        var tags_result = turso.query(
            "SELECT document_uri, tag FROM document_tags",
            &.{},
        ) catch |err| {
            logfire.warn("sync: turso tags query failed: {}", .{err});
            return;
        };
        defer tags_result.deinit();

        local.lock();
        defer local.unlock();
        conn.exec("BEGIN", .{}) catch {};
        for (tags_result.rows) |row| {
            conn.exec(
                "INSERT OR IGNORE INTO document_tags (document_uri, tag) VALUES (?, ?)",
                .{ row.text(0), row.text(1) },
            ) catch {};
            tag_count += 1;
        }
        conn.exec("COMMIT", .{}) catch {};
    }

    // sync popular searches
    var popular_count: usize = 0;
    {
        var popular_result = turso.query(
            "SELECT query, count FROM popular_searches",
            &.{},
        ) catch |err| {
            logfire.warn("sync: turso popular_searches query failed: {}", .{err});
            return;
        };
        defer popular_result.deinit();

        local.lock();
        defer local.unlock();
        conn.exec("DELETE FROM popular_searches", .{}) catch {};
        conn.exec("BEGIN", .{}) catch {};
        for (popular_result.rows) |row| {
            conn.exec(
                "INSERT OR REPLACE INTO popular_searches (query, count) VALUES (?, ?)",
                .{ row.text(0), row.text(1) },
            ) catch {};
            popular_count += 1;
        }
        conn.exec("COMMIT", .{}) catch {};
    }

    // clean up stale docs that were deleted from Turso (brief lock)
    {
        local.lock();
        defer local.unlock();
        conn.exec("DELETE FROM documents_fts WHERE uri NOT IN (SELECT uri FROM _synced_uris)", .{}) catch {};
        conn.exec("DELETE FROM documents WHERE uri NOT IN (SELECT uri FROM _synced_uris)", .{}) catch {};
        conn.exec("DELETE FROM document_tags WHERE document_uri NOT IN (SELECT uri FROM _synced_uris)", .{}) catch {};
        conn.exec("DROP TABLE IF EXISTS _synced_uris", .{}) catch {};
    }

    // record sync time (brief lock)
    {
        local.lock();
        defer local.unlock();
        var ts_buf: [20]u8 = undefined;
        const now_s: i64 = @intCast(@divFloor(Io.Timestamp.now(turso.io, .real).nanoseconds, std.time.ns_per_s));
        const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{now_s}) catch "0";
        conn.exec(
            "INSERT OR REPLACE INTO sync_meta (key, value) VALUES ('last_sync', ?)",
            .{ts_str},
        ) catch {};
    }

    // checkpoint WAL to prevent unbounded growth
    {
        local.lock();
        defer local.unlock();
        conn.exec("PRAGMA wal_checkpoint(PASSIVE)", .{}) catch |err| {
            logfire.warn("sync: wal checkpoint failed: {}", .{err});
        };
    }

    local.setReady(true);
    std.debug.print("sync: full sync complete - {d} docs, {d} pubs, {d} tags, {d} popular\n", .{ doc_count, pub_count, tag_count, popular_count });
}

pub const BuildCounts = struct {
    documents: usize = 0,
    publications: usize = 0,
    tags: usize = 0,
    popular: usize = 0,
    recommends: usize = 0,
};

const BUILD_PAGE_SIZE = 500;

// Snapshot-build page query. Two non-negotiable filters (policy.zig): turso
// still holds historical rows for banned DIDs and bridgy-flagged docs until
// the paced cleanup finishes, and a snapshot must never resurrect them.
// Keyset pagination on the uri PK keeps turso row reads linear (an OFFSET
// walk re-scans from the start every page — the 2026-06 access-pattern
// lesson).
const BUILD_DOC_PAGE_SQL =
    "SELECT uri, did, rkey, title, content, created_at, publication_uri, " ++
    "platform, source_collection, path, base_path, has_publication, indexed_at, embedded_at, " ++
    "COALESCE(cover_image, '') as cover_image, COALESCE(is_bridgyfed, 0) as is_bridgyfed, " ++
    "COALESCE(url_dead, 0) as url_dead " ++
    "FROM documents WHERE uri > ? " ++
    "AND indexed_at <= ? " ++
    "AND COALESCE(is_bridgyfed, 0) NOT IN (1, '1') " ++
    "AND did NOT IN (" ++ policy.banned_dids_sql ++ ") " ++
    "ORDER BY uri LIMIT 500";

pub const BUILD_DOC_COUNT_SQL =
    "SELECT COUNT(*) FROM documents " ++
    "WHERE indexed_at <= ? " ++
    "AND COALESCE(is_bridgyfed, 0) NOT IN (1, '1') " ++
    "AND did NOT IN (" ++ policy.banned_dids_sql ++ ")";

const BUILD_PUB_SQL =
    "SELECT uri, did, rkey, name, description, base_path, platform, indexed_at " ++
    "FROM publications WHERE did NOT IN (" ++ policy.banned_dids_sql ++ ")";

// watermark-pinned like documents (NULL indexed_at sorts as old → included)
const BUILD_REC_SQL =
    "SELECT uri, did, rkey, document_uri, COALESCE(created_at, ''), COALESCE(indexed_at, '') " ++
    "FROM recommends WHERE COALESCE(indexed_at, '') <= ? " ++
    "AND did NOT IN (" ++ policy.banned_dids_sql ++ ")";

pub const BUILD_REC_COUNT_SQL =
    "SELECT COUNT(*) FROM recommends WHERE COALESCE(indexed_at, '') <= ? " ++
    "AND did NOT IN (" ++ policy.banned_dids_sql ++ ")";

/// Offline snapshot build: populate a FRESH local db from turso. The target
/// must never be the serving replica — the builder runs off-box (builder.zig)
/// and pacing between pages keeps turso comfortable while production reads it
/// (2026-06-10 wedge lesson: bulk ops own their blast radius).
///
/// The build is PINNED to `indexed_at <= watermark`: docs written mid-build
/// are excluded, so the manifest's source_watermark is an exact contract —
/// the snapshot contains every (policy-passing) doc at or before it and
/// nothing after. The overlay/promote side depends on this for its freshness
/// cutoff. (Watermark semantics cover documents; publications/tags are small
/// and copied whole.)
pub fn buildSnapshot(turso: *Client, local: *LocalDb, watermark: []const u8) !BuildCounts {
    const conn = local.getConn() orelse return error.LocalNotOpen;
    var counts: BuildCounts = .{};

    var cursor_buf: [512]u8 = undefined;
    var cursor: []const u8 = "";
    while (true) {
        var result = turso.query(BUILD_DOC_PAGE_SQL, &.{ cursor, watermark }) catch |err| {
            logfire.err("build: turso document page failed at cursor {s}: {}", .{ cursor, err });
            return err;
        };
        defer result.deinit();

        if (result.rows.len == 0) break;

        conn.exec("BEGIN", .{}) catch {};
        for (result.rows) |row| {
            try insertDocumentLocal(conn, row);
            counts.documents += 1;
        }
        conn.exec("COMMIT", .{}) catch {};

        const last_uri = result.rows[result.rows.len - 1].text(0);
        if (last_uri.len >= cursor_buf.len) return error.UriTooLong;
        @memcpy(cursor_buf[0..last_uri.len], last_uri);
        cursor = cursor_buf[0..last_uri.len];

        if (counts.documents % 5000 < BUILD_PAGE_SIZE) {
            std.debug.print("build: {d} documents...\n", .{counts.documents});
        }
        if (result.rows.len < BUILD_PAGE_SIZE) break;

        // pacing: the builder shares turso with production reads
        turso.io.sleep(Io.Duration.fromMilliseconds(150), .awake) catch {};
    }

    {
        var pub_result = turso.query(BUILD_PUB_SQL, &.{}) catch |err| {
            logfire.err("build: turso publications query failed: {}", .{err});
            return err;
        };
        defer pub_result.deinit();

        conn.exec("BEGIN", .{}) catch {};
        for (pub_result.rows) |row| {
            try insertPublicationLocal(conn, row);
            counts.publications += 1;
        }
        conn.exec("COMMIT", .{}) catch {};
    }

    {
        var tags_result = turso.query("SELECT document_uri, tag FROM document_tags", &.{}) catch |err| {
            logfire.err("build: turso tags query failed: {}", .{err});
            return err;
        };
        defer tags_result.deinit();

        conn.exec("BEGIN", .{}) catch {};
        for (tags_result.rows) |row| {
            conn.exec(
                "INSERT OR IGNORE INTO document_tags (document_uri, tag) VALUES (?, ?)",
                .{ row.text(0), row.text(1) },
            ) catch {};
            counts.tags += 1;
        }
        conn.exec("COMMIT", .{}) catch {};

        // tags were copied unfiltered; drop the ones whose documents the
        // policy filters excluded (local-side, cheap)
        conn.exec("DELETE FROM document_tags WHERE document_uri NOT IN (SELECT uri FROM documents)", .{}) catch {};
    }

    {
        var rec_result = turso.query(BUILD_REC_SQL, &.{watermark}) catch |err| {
            logfire.err("build: turso recommends query failed: {}", .{err});
            return err;
        };
        defer rec_result.deinit();

        conn.exec("BEGIN", .{}) catch {};
        for (rec_result.rows) |row| {
            conn.exec(
                "INSERT OR REPLACE INTO recommends (uri, did, rkey, document_uri, created_at, indexed_at) VALUES (?, ?, ?, ?, ?, ?)",
                .{ row.text(0), row.text(1), row.text(2), row.text(3), row.text(4), row.text(5) },
            ) catch {};
            counts.recommends += 1;
        }
        conn.exec("COMMIT", .{}) catch {};
    }

    {
        var popular_result = turso.query("SELECT query, count FROM popular_searches", &.{}) catch |err| {
            logfire.err("build: turso popular_searches query failed: {}", .{err});
            return err;
        };
        defer popular_result.deinit();

        conn.exec("BEGIN", .{}) catch {};
        for (popular_result.rows) |row| {
            conn.exec(
                "INSERT OR REPLACE INTO popular_searches (query, count) VALUES (?, ?)",
                .{ row.text(0), row.text(1) },
            ) catch {};
            counts.popular += 1;
        }
        conn.exec("COMMIT", .{}) catch {};
    }

    return counts;
}

/// Incremental sync: fetch documents created since last sync
pub fn incrementalSync(turso: *Client, local: *LocalDb) !void {
    const sync_span = logfire.span("sync.incremental", .{});
    defer sync_span.end();

    const conn = local.getConn() orelse {
        sync_span.recordError(error.LocalNotOpen);
        return error.LocalNotOpen;
    };

    // get last sync time
    local.lock();
    const last_sync_ts = blk: {
        const row = conn.row(
            "SELECT value FROM sync_meta WHERE key = 'last_sync'",
            .{},
        ) catch {
            local.unlock();
            break :blk @as(i64, 0);
        };
        if (row) |r| {
            defer r.deinit();
            const val = r.text(0);
            local.unlock();
            // empty string (NULL) or invalid -> 0
            break :blk if (val.len == 0) 0 else std.fmt.parseInt(i64, val, 10) catch 0;
        }
        local.unlock();
        break :blk @as(i64, 0);
    };

    if (last_sync_ts == 0) {
        // no previous sync, do full sync
        std.debug.print("sync: no last_sync found, doing full sync\n", .{});
        return fullSync(turso, local);
    }

    // local has data from a previous sync — mark ready immediately
    local.setReady(true);

    // convert timestamp to ISO date for query
    // rough estimate: subtract 5 minutes buffer to catch any stragglers
    const since_ts = last_sync_ts - 300;
    const epoch_secs: u64 = @intCast(since_ts);
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day_secs = epoch.getDaySeconds();
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var since_buf: [24]u8 = undefined;
    const since_str = std.fmt.bufPrint(&since_buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch {
        logfire.warn("sync: failed to format since date", .{});
        return;
    };

    std.debug.print("sync: incremental sync since {s}\n", .{since_str});
    sync_span.setAttribute("since", since_str);

    // fetch new documents (use indexed_at, not created_at, because resynced
    // documents can have old publication dates but recent insertion times).
    //
    // Paged via keyset (indexed_at, uri) — an unbounded since-window query
    // grows without limit while sync keeps failing, until the response is
    // structurally unfetchable (7h stall + memory churn, 2026-06-10). Pages
    // are bounded regardless of how far behind we are, and each page holds
    // the local write lock only briefly.
    //
    // PAGE_SIZE is set by payload, not row count: patent docs average ~24KB,
    // and responses beyond tens of MB stall the backend's http path (turso
    // itself serves them in ~1s — measured). 100 rows ≈ 2.5MB per page.
    var new_docs: usize = 0;
    {
        var cursor_at_buf: [40]u8 = undefined;
        var cursor_uri_buf: [256]u8 = undefined;
        var cursor_at: []const u8 = std.fmt.bufPrint(&cursor_at_buf, "{s}", .{since_str}) catch since_str;
        var cursor_uri: []const u8 = "";

        var page_n: usize = 0;
        while (true) {
            page_n += 1;
            std.debug.print("sync: fetching page {d} (cursor {s})\n", .{ page_n, cursor_at });
            var result = turso.query(
                \\SELECT uri, did, rkey, title, content, created_at, publication_uri,
                \\  platform, source_collection, path, base_path, has_publication, indexed_at, embedded_at,
                \\  COALESCE(cover_image, '') as cover_image, COALESCE(is_bridgyfed, 0) as is_bridgyfed,
                \\  COALESCE(url_dead, 0) as url_dead
                \\FROM documents
                \\WHERE (indexed_at, uri) > (?, ?)
                \\ORDER BY indexed_at, uri
                \\LIMIT 100
            , &.{ cursor_at, cursor_uri }) catch |err| {
                logfire.warn("sync: incremental query failed (after {d} docs this cycle): {}", .{ new_docs, err });
                sync_span.recordError(err);
                return;
            };
            defer result.deinit();

            std.debug.print("sync: page {d} -> {d} rows\n", .{ page_n, result.rows.len });
            if (result.rows.len == 0) break;

            {
                local.lock();
                defer local.unlock();
                for (result.rows) |row| {
                    insertDocumentLocal(conn, row) catch {};
                    new_docs += 1;
                }
            }

            // advance the keyset cursor past the last row of this page
            const last = result.rows[result.rows.len - 1];
            cursor_at = std.fmt.bufPrint(&cursor_at_buf, "{s}", .{last.text(12)}) catch break;
            cursor_uri = std.fmt.bufPrint(&cursor_uri_buf, "{s}", .{last.text(0)}) catch break;

            if (result.rows.len < 100) break;
        }

        // update sync time only after the full window landed
        local.lock();
        defer local.unlock();
        var ts_buf: [20]u8 = undefined;
        const inc_now_s: i64 = @intCast(@divFloor(Io.Timestamp.now(turso.io, .real).nanoseconds, std.time.ns_per_s));
        const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{inc_now_s}) catch "0";
        conn.exec(
            "INSERT OR REPLACE INTO sync_meta (key, value) VALUES ('last_sync', ?)",
            .{ts_str},
        ) catch {};
    }

    // fetch new/updated publications (same since_str as documents).
    // publications were silently missing from incremental sync before
    // `publications.indexed_at` was added — they only synced on fullSync,
    // so the local replica drifted by hundreds of rows over time.
    var new_pubs: usize = 0;
    pubs: {
        var pub_result = turso.query(
            \\SELECT uri, did, rkey, name, description, base_path, platform, indexed_at
            \\FROM publications
            \\WHERE indexed_at >= ?
            \\ORDER BY indexed_at
        , &.{since_str}) catch |err| {
            logfire.warn("sync: incremental publications query failed: {}", .{err});
            sync_span.recordError(err);
            // fall through to tombstones — don't abort entire sync
            break :pubs;
        };
        defer pub_result.deinit();

        local.lock();
        defer local.unlock();

        for (pub_result.rows) |row| {
            insertPublicationLocal(conn, row) catch {};
            new_pubs += 1;
        }
    }

    // sync deletions via tombstones (deleted_at is unix timestamp integer)
    var deleted: usize = 0;
    tombstone: {
        var since_ts_buf: [20]u8 = undefined;
        const since_ts_str = std.fmt.bufPrint(&since_ts_buf, "{d}", .{since_ts}) catch break :tombstone;

        var tomb_result = turso.query(
            "SELECT uri, record_type FROM tombstones WHERE deleted_at >= ?",
            &.{since_ts_str},
        ) catch |err| {
            logfire.warn("sync: tombstone query failed: {}", .{err});
            sync_span.recordError(err);
            break :tombstone;
        };
        defer tomb_result.deinit();

        if (tomb_result.rows.len > 0) {
            local.lock();
            defer local.unlock();
            for (tomb_result.rows) |row| {
                const uri = row.text(0);
                const record_type = row.text(1);
                if (std.mem.eql(u8, record_type, "document")) {
                    // FTS keyed by documents.rowid — drop it before the row
                    conn.exec("DELETE FROM documents_fts WHERE rowid = (SELECT rowid FROM documents WHERE uri = ?)", .{uri}) catch {};
                    conn.exec("DELETE FROM documents WHERE uri = ?", .{uri}) catch {};
                    conn.exec("DELETE FROM document_tags WHERE document_uri = ?", .{uri}) catch {};
                } else if (std.mem.eql(u8, record_type, "publication")) {
                    conn.exec("DELETE FROM publications WHERE uri = ?", .{uri}) catch {};
                    conn.exec("DELETE FROM publications_fts WHERE uri = ?", .{uri}) catch {};
                }
                deleted += 1;
            }
        }
    }

    // periodic WAL checkpoint to prevent unbounded growth
    local.lock();
    conn.exec("PRAGMA wal_checkpoint(PASSIVE)", .{}) catch {};
    local.unlock();

    sync_span.setAttribute("new_docs", @as(i64, @intCast(new_docs)));
    sync_span.setAttribute("new_pubs", @as(i64, @intCast(new_pubs)));
    sync_span.setAttribute("deleted", @as(i64, @intCast(deleted)));

    if (new_docs > 0 or new_pubs > 0 or deleted > 0) {
        std.debug.print("sync: incremental sync — {d} new docs, {d} new pubs, {d} tombstone deletions\n", .{ new_docs, new_pubs, deleted });
    }
}

fn insertDocumentLocal(conn: zqlite.Conn, row: anytype) !void {
    // FTS is keyed to documents.rowid so deletes are an O(1) rowid drop rather
    // than a uri-UNINDEXED full-scan (same pathology fixed turso-side in the
    // indexer; unchecked, a busy cycle held the local write lock for 300s+ and
    // wedged everything sharing it — 2026-06-10 stats/dashboard outage).
    // INSERT OR REPLACE below assigns a FRESH rowid, so the stale FTS row must
    // be dropped by its CURRENT rowid now, before the replace. New docs (the
    // majority) have no row and skip this entirely.
    var old_rowid: ?i64 = null;
    if (conn.row("SELECT rowid FROM documents WHERE uri = ?", .{row.text(0)}) catch null) |r| {
        old_rowid = r.int(0);
        r.deinit();
    }
    if (old_rowid) |rid| {
        conn.exec("DELETE FROM documents_fts WHERE rowid = ?", .{rid}) catch {};
    }

    // insert into main table
    conn.exec(
        \\INSERT OR REPLACE INTO documents
        \\(uri, did, rkey, title, content, created_at, publication_uri,
        \\ platform, source_collection, path, base_path, has_publication, indexed_at, embedded_at, cover_image, is_bridgyfed, url_dead)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    , .{
        row.text(0), // uri
        row.text(1), // did
        row.text(2), // rkey
        row.text(3), // title
        row.text(4), // content
        row.text(5), // created_at
        row.text(6), // publication_uri
        row.text(7), // platform
        row.text(8), // source_collection
        row.text(9), // path
        row.text(10), // base_path
        row.int(11), // has_publication
        row.text(12), // indexed_at
        row.text(13), // embedded_at
        row.text(14), // cover_image
        row.int(15), // is_bridgyfed
        row.int(16), // url_dead
    }) catch |err| {
        return err;
    };

    // re-insert FTS keyed to the new documents.rowid (stale row already
    // dropped above, before the replace reassigned the rowid)
    const uri = row.text(0);
    conn.exec(
        "INSERT INTO documents_fts (rowid, uri, title, content) VALUES ((SELECT rowid FROM documents WHERE uri = ?), ?, ?, ?)",
        .{ uri, uri, row.text(3), row.text(4) },
    ) catch {};
}

fn insertPublicationLocal(conn: zqlite.Conn, row: anytype) !void {
    // insert into main table (no created_at - Turso publications table doesn't have it)
    conn.exec(
        \\INSERT OR REPLACE INTO publications
        \\(uri, did, rkey, name, description, base_path, platform, indexed_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    , .{
        row.text(0), // uri
        row.text(1), // did
        row.text(2), // rkey
        row.text(3), // name
        row.text(4), // description
        row.text(5), // base_path
        row.text(6), // platform
        row.text(7), // indexed_at
    }) catch |err| {
        return err;
    };

    // update FTS
    const uri = row.text(0);
    conn.exec("DELETE FROM publications_fts WHERE uri = ?", .{uri}) catch {};
    conn.exec(
        "INSERT INTO publications_fts (uri, name, description, base_path) VALUES (?, ?, ?, ?)",
        .{ uri, row.text(3), row.text(4), row.text(5) },
    ) catch {};
}

// --- tests ---

test "insertDocumentLocal keys FTS by rowid: no orphans on update, MATCH works" {
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite);
    defer conn.close();
    try conn.exec(
        \\CREATE TABLE documents (
        \\  uri TEXT PRIMARY KEY, did TEXT, rkey TEXT, title TEXT, content TEXT,
        \\  created_at TEXT, publication_uri TEXT, platform TEXT, source_collection TEXT,
        \\  path TEXT, base_path TEXT, has_publication INTEGER, indexed_at TEXT,
        \\  embedded_at TEXT, cover_image TEXT, is_bridgyfed INTEGER, url_dead INTEGER
        \\)
    , .{});
    try conn.exec("CREATE VIRTUAL TABLE documents_fts USING fts5(uri UNINDEXED, title, content)", .{});

    // a fake turso row exposing the .text()/.int() accessors insertDocumentLocal reads
    const FakeRow = struct {
        uri: []const u8,
        title: []const u8,
        content: []const u8,
        fn text(self: @This(), i: usize) []const u8 {
            return switch (i) {
                0 => self.uri,
                3 => self.title,
                4 => self.content,
                else => "",
            };
        }
        fn int(_: @This(), _: usize) i64 {
            return 0;
        }
    };

    try insertDocumentLocal(conn, FakeRow{ .uri = "at://a", .title = "first", .content = "hello world" });
    // same uri, replacement (INSERT OR REPLACE reassigns documents.rowid)
    try insertDocumentLocal(conn, FakeRow{ .uri = "at://a", .title = "second", .content = "hello world" });

    // exactly one FTS row — the stale one was dropped, not orphaned
    {
        const r = (try conn.row("SELECT COUNT(*) FROM documents_fts", .{})).?;
        defer r.deinit();
        try std.testing.expectEqual(@as(i64, 1), r.int(0));
    }
    // it reflects the updated title
    {
        const r = (try conn.row("SELECT title FROM documents_fts", .{})).?;
        defer r.deinit();
        try std.testing.expectEqualStrings("second", r.text(0));
    }
    // FTS rowid stayed aligned to documents.rowid after the replace
    {
        const r = (try conn.row("SELECT (SELECT rowid FROM documents WHERE uri = f.uri) = f.rowid FROM documents_fts f", .{})).?;
        defer r.deinit();
        try std.testing.expectEqual(@as(i64, 1), r.int(0));
    }
    // the read path (MATCH) still finds it
    {
        const r = (try conn.row("SELECT COUNT(*) FROM documents_fts WHERE documents_fts MATCH 'hello'", .{})).?;
        defer r.deinit();
        try std.testing.expectEqual(@as(i64, 1), r.int(0));
    }
}
