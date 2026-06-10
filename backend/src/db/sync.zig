//! Sync from Turso to local SQLite
//! Full sync on startup, incremental sync periodically

const std = @import("std");
const Io = std.Io;
const zqlite = @import("zqlite");
const logfire = @import("logfire");
const Allocator = std.mem.Allocator;
const Client = @import("Client.zig");
const LocalDb = @import("LocalDb.zig");

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
    // documents can have old publication dates but recent insertion times)
    var new_docs: usize = 0;
    {
        var result = turso.query(
            \\SELECT uri, did, rkey, title, content, created_at, publication_uri,
            \\  platform, source_collection, path, base_path, has_publication, indexed_at, embedded_at,
            \\  COALESCE(cover_image, '') as cover_image, COALESCE(is_bridgyfed, 0) as is_bridgyfed,
            \\  COALESCE(url_dead, 0) as url_dead
            \\FROM documents
            \\WHERE indexed_at >= ?
            \\ORDER BY indexed_at
        , &.{since_str}) catch |err| {
            logfire.warn("sync: incremental query failed: {}", .{err});
            sync_span.recordError(err);
            return;
        };
        defer result.deinit();

        local.lock();
        defer local.unlock();

        for (result.rows) |row| {
            insertDocumentLocal(conn, row) catch {};
            new_docs += 1;
        }

        // update sync time
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
                    conn.exec("DELETE FROM documents WHERE uri = ?", .{uri}) catch {};
                    conn.exec("DELETE FROM documents_fts WHERE uri = ?", .{uri}) catch {};
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
    // FTS delete-by-uri full-scans documents_fts (uri is UNINDEXED — same
    // pathology as the turso-side indexer fix). Most incremental rows are NEW
    // docs, so check the PK first (sub-ms) and only pay the scan on real
    // replacements. Unchecked, a busy cycle held the local write lock for
    // 300s+ and wedged everything sharing it (2026-06-10 stats/dashboard
    // outage).
    var fts_stale = false;
    if (conn.row("SELECT 1 FROM documents WHERE uri = ?", .{row.text(0)}) catch null) |r| {
        defer r.deinit();
        fts_stale = true;
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

    // update FTS (scan-on-replace only — see fts_stale above)
    const uri = row.text(0);
    if (fts_stale) {
        conn.exec("DELETE FROM documents_fts WHERE uri = ?", .{uri}) catch {};
    }
    conn.exec(
        "INSERT INTO documents_fts (uri, title, content) VALUES (?, ?, ?)",
        .{ uri, row.text(3), row.text(4) },
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
