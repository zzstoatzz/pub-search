//! Sync from Turso to local SQLite
//! Full sync on startup, incremental sync periodically

const std = @import("std");
const zqlite = @import("zqlite");
const Allocator = std.mem.Allocator;
const Client = @import("Client.zig");
const LocalDb = @import("LocalDb.zig");

const BATCH_SIZE = 500;

/// Full sync: fetch all data from Turso and populate local SQLite
/// Local stays not-ready during sync — search goes to Turso (no mutex there).
/// When sync completes, local becomes ready and search uses the fast local path.
pub fn fullSync(turso: *Client, local: *LocalDb) !void {
    std.debug.print("sync: starting full sync...\n", .{});

    local.setReady(false);

    const conn = local.getConn() orelse return error.LocalNotOpen;

    // clear existing data
    {
        local.lock();
        defer local.unlock();
        conn.exec("DELETE FROM documents_fts", .{}) catch {};
        conn.exec("DELETE FROM documents", .{}) catch {};
        conn.exec("DELETE FROM publications_fts", .{}) catch {};
        conn.exec("DELETE FROM publications", .{}) catch {};
        conn.exec("DELETE FROM document_tags", .{}) catch {};
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
            \\  platform, source_collection, path, base_path, has_publication, indexed_at
            \\FROM documents
            \\ORDER BY uri
            \\LIMIT 500 OFFSET ?
        , &.{offset_str}) catch |err| {
            std.debug.print("sync: turso query failed: {}\n", .{err});
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
                    std.debug.print("sync: insert doc failed: {}\n", .{err});
                };
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
            "SELECT uri, did, rkey, name, description, base_path, platform FROM publications",
            &.{},
        ) catch |err| {
            std.debug.print("sync: turso publications query failed: {}\n", .{err});
            return;
        };
        defer pub_result.deinit();

        local.lock();
        defer local.unlock();
        conn.exec("BEGIN", .{}) catch {};
        for (pub_result.rows) |row| {
            insertPublicationLocal(conn, row) catch |err| {
                std.debug.print("sync: insert pub failed: {}\n", .{err});
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
            std.debug.print("sync: turso tags query failed: {}\n", .{err});
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
            std.debug.print("sync: turso popular_searches query failed: {}\n", .{err});
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

    // record sync time (brief lock)
    {
        local.lock();
        defer local.unlock();
        var ts_buf: [20]u8 = undefined;
        const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch "0";
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
            std.debug.print("sync: wal checkpoint failed: {}\n", .{err});
        };
    }

    local.setReady(true);
    std.debug.print("sync: full sync complete - {d} docs, {d} pubs, {d} tags, {d} popular\n", .{ doc_count, pub_count, tag_count, popular_count });
}

/// Incremental sync: fetch documents created since last sync
pub fn incrementalSync(turso: *Client, local: *LocalDb) !void {
    const conn = local.getConn() orelse return error.LocalNotOpen;

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
        std.debug.print("sync: failed to format since date\n", .{});
        return;
    };

    std.debug.print("sync: incremental sync since {s}\n", .{since_str});

    // fetch new documents (use indexed_at, not created_at, because resynced
    // documents can have old publication dates but recent insertion times)
    var new_docs: usize = 0;
    {
        var result = turso.query(
            \\SELECT uri, did, rkey, title, content, created_at, publication_uri,
            \\  platform, source_collection, path, base_path, has_publication, indexed_at
            \\FROM documents
            \\WHERE indexed_at >= ?
            \\ORDER BY indexed_at
        , &.{since_str}) catch |err| {
            std.debug.print("sync: incremental query failed: {}\n", .{err});
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
        const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch "0";
        conn.exec(
            "INSERT OR REPLACE INTO sync_meta (key, value) VALUES ('last_sync', ?)",
            .{ts_str},
        ) catch {};
    }

    // periodic WAL checkpoint to prevent unbounded growth
    local.lock();
    conn.exec("PRAGMA wal_checkpoint(PASSIVE)", .{}) catch {};
    local.unlock();

    if (new_docs > 0) {
        std.debug.print("sync: incremental sync added {d} new documents\n", .{new_docs});
    }
}

fn insertDocumentLocal(conn: zqlite.Conn, row: anytype) !void {
    // insert into main table
    conn.exec(
        \\INSERT OR REPLACE INTO documents
        \\(uri, did, rkey, title, content, created_at, publication_uri,
        \\ platform, source_collection, path, base_path, has_publication, indexed_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    , .{
        row.text(0),  // uri
        row.text(1),  // did
        row.text(2),  // rkey
        row.text(3),  // title
        row.text(4),  // content
        row.text(5),  // created_at
        row.text(6),  // publication_uri
        row.text(7),  // platform
        row.text(8),  // source_collection
        row.text(9),  // path
        row.text(10), // base_path
        row.int(11),  // has_publication
        row.text(12), // indexed_at
    }) catch |err| {
        return err;
    };

    // update FTS
    const uri = row.text(0);
    conn.exec("DELETE FROM documents_fts WHERE uri = ?", .{uri}) catch {};
    conn.exec(
        "INSERT INTO documents_fts (uri, title, content) VALUES (?, ?, ?)",
        .{ uri, row.text(3), row.text(4) },
    ) catch {};
}

fn insertPublicationLocal(conn: zqlite.Conn, row: anytype) !void {
    // insert into main table (no created_at - Turso publications table doesn't have it)
    conn.exec(
        \\INSERT OR REPLACE INTO publications
        \\(uri, did, rkey, name, description, base_path, platform)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    , .{
        row.text(0), // uri
        row.text(1), // did
        row.text(2), // rkey
        row.text(3), // name
        row.text(4), // description
        row.text(5), // base_path
        row.text(6), // platform
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
