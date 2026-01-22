//! Sync from Turso to local SQLite
//! Full sync on startup, incremental sync periodically

const std = @import("std");
const zqlite = @import("zqlite");
const Allocator = std.mem.Allocator;
const Client = @import("Client.zig");
const LocalDb = @import("LocalDb.zig");

const BATCH_SIZE = 500;

/// Full sync: fetch all data from Turso and populate local SQLite
pub fn fullSync(turso: *Client, local: *LocalDb) !void {
    std.debug.print("sync: starting full sync...\n", .{});

    local.setReady(false);

    const conn = local.getConn() orelse return error.LocalNotOpen;

    local.lock();
    defer local.unlock();

    // start transaction for bulk insert
    conn.exec("BEGIN IMMEDIATE", .{}) catch |err| {
        std.debug.print("sync: failed to begin transaction: {}\n", .{err});
        return err;
    };
    errdefer conn.exec("ROLLBACK", .{}) catch {};

    // clear existing data
    conn.exec("DELETE FROM documents_fts", .{}) catch {};
    conn.exec("DELETE FROM documents", .{}) catch {};
    conn.exec("DELETE FROM publications_fts", .{}) catch {};
    conn.exec("DELETE FROM publications", .{}) catch {};
    conn.exec("DELETE FROM document_tags", .{}) catch {};

    // sync documents in batches
    var doc_count: usize = 0;
    var offset: usize = 0;
    while (true) {
        var offset_buf: [16]u8 = undefined;
        const offset_str = std.fmt.bufPrint(&offset_buf, "{d}", .{offset}) catch break;

        var result = turso.query(
            \\SELECT uri, did, rkey, title, content, created_at, publication_uri,
            \\  platform, source_collection, path, base_path, has_publication
            \\FROM documents
            \\ORDER BY uri
            \\LIMIT 500 OFFSET ?
        , &.{offset_str}) catch |err| {
            std.debug.print("sync: turso query failed: {}\n", .{err});
            break;
        };
        defer result.deinit();

        if (result.rows.len == 0) break;

        for (result.rows) |row| {
            insertDocumentLocal(conn, row) catch |err| {
                std.debug.print("sync: insert doc failed: {}\n", .{err});
            };
            doc_count += 1;
        }

        offset += result.rows.len;
        if (offset % 1000 == 0) {
            std.debug.print("sync: synced {d} documents...\n", .{offset});
        }
    }

    // sync publications
    var pub_count: usize = 0;
    {
        var pub_result = turso.query(
            "SELECT uri, did, rkey, name, description, base_path, platform, created_at FROM publications",
            &.{},
        ) catch |err| {
            std.debug.print("sync: turso publications query failed: {}\n", .{err});
            conn.exec("COMMIT", .{}) catch {};
            local.setReady(true);
            return;
        };
        defer pub_result.deinit();

        for (pub_result.rows) |row| {
            insertPublicationLocal(conn, row) catch |err| {
                std.debug.print("sync: insert pub failed: {}\n", .{err});
            };
            pub_count += 1;
        }
    }

    // sync tags
    var tag_count: usize = 0;
    {
        var tags_result = turso.query(
            "SELECT document_uri, tag FROM document_tags",
            &.{},
        ) catch |err| {
            std.debug.print("sync: turso tags query failed: {}\n", .{err});
            conn.exec("COMMIT", .{}) catch {};
            local.setReady(true);
            return;
        };
        defer tags_result.deinit();

        for (tags_result.rows) |row| {
            conn.exec(
                "INSERT OR IGNORE INTO document_tags (document_uri, tag) VALUES (?, ?)",
                .{ row.text(0), row.text(1) },
            ) catch {};
            tag_count += 1;
        }
    }

    // record sync time
    var ts_buf: [20]u8 = undefined;
    const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch "0";
    conn.exec(
        "INSERT OR REPLACE INTO sync_meta (key, value) VALUES ('last_sync', ?)",
        .{ts_str},
    ) catch {};

    conn.exec("COMMIT", .{}) catch |err| {
        std.debug.print("sync: commit failed: {}\n", .{err});
        return err;
    };

    local.setReady(true);
    std.debug.print("sync: full sync complete - {d} docs, {d} pubs, {d} tags\n", .{ doc_count, pub_count, tag_count });
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

    // fetch new documents
    var new_docs: usize = 0;
    {
        var result = turso.query(
            \\SELECT uri, did, rkey, title, content, created_at, publication_uri,
            \\  platform, source_collection, path, base_path, has_publication
            \\FROM documents
            \\WHERE created_at >= ?
            \\ORDER BY created_at
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

    if (new_docs > 0) {
        std.debug.print("sync: incremental sync added {d} new documents\n", .{new_docs});
    }
}

fn insertDocumentLocal(conn: zqlite.Conn, row: anytype) !void {
    // insert into main table
    conn.exec(
        \\INSERT OR REPLACE INTO documents
        \\(uri, did, rkey, title, content, created_at, publication_uri,
        \\ platform, source_collection, path, base_path, has_publication)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
    // insert into main table
    conn.exec(
        \\INSERT OR REPLACE INTO publications
        \\(uri, did, rkey, name, description, base_path, platform, created_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    , .{
        row.text(0), // uri
        row.text(1), // did
        row.text(2), // rkey
        row.text(3), // name
        row.text(4), // description
        row.text(5), // base_path
        row.text(6), // platform
        row.text(7), // created_at
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
