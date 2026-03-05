//! Background worker for reconciling stale documents.
//!
//! Periodically verifies documents still exist at their source PDS.
//! Documents that return 400/404 from com.atproto.repo.getRecord are
//! deleted from turso and turbopuffer.
//!
//! This catches deletions that tap resync cannot — resync only re-sends
//! records that still exist, so documents deleted at the PDS between
//! resyncs become ghosts. The reconciler verifies them directly.

const std = @import("std");
const http = std.http;
const json = std.json;
const mem = std.mem;
const posix = std.posix;
const Allocator = mem.Allocator;
const logfire = @import("logfire");
const db = @import("../db.zig");
const tpuf = @import("../tpuf.zig");
const indexer = @import("indexer.zig");

// config (env vars with defaults)
fn getIntervalSecs() u64 {
    const val = posix.getenv("RECONCILE_INTERVAL_SECS") orelse "1800";
    return std.fmt.parseInt(u64, val, 10) catch 1800;
}

fn getBatchSize() usize {
    const val = posix.getenv("RECONCILE_BATCH_SIZE") orelse "50";
    return std.fmt.parseInt(usize, val, 10) catch 50;
}

fn getReverifyDays() u64 {
    const val = posix.getenv("RECONCILE_REVERIFY_DAYS") orelse "7";
    return std.fmt.parseInt(u64, val, 10) catch 7;
}

fn isEnabled() bool {
    const val = posix.getenv("RECONCILE_ENABLED") orelse "true";
    return !mem.eql(u8, val, "false") and !mem.eql(u8, val, "0");
}

/// AT-URI components parsed from "at://{did}/{collection}/{rkey}"
const UriParts = struct {
    did: []const u8,
    collection: []const u8,
    rkey: []const u8,
};

fn parseAtUri(uri: []const u8) ?UriParts {
    const prefix = "at://";
    if (!mem.startsWith(u8, uri, prefix)) return null;
    const rest = uri[prefix.len..];

    const first_slash = mem.indexOf(u8, rest, "/") orelse return null;
    const did = rest[0..first_slash];
    const after_did = rest[first_slash + 1 ..];

    const second_slash = mem.indexOf(u8, after_did, "/") orelse return null;
    const collection = after_did[0..second_slash];
    const rkey = after_did[second_slash + 1 ..];

    if (did.len == 0 or collection.len == 0 or rkey.len == 0) return null;
    return .{ .did = did, .collection = collection, .rkey = rkey };
}

/// Start the reconciler background worker.
pub fn start(allocator: Allocator) void {
    if (!isEnabled()) {
        logfire.info("reconcile: disabled via RECONCILE_ENABLED", .{});
        return;
    }

    const thread = std.Thread.spawn(.{}, worker, .{allocator}) catch |err| {
        logfire.err("reconcile: failed to start thread: {}", .{err});
        return;
    };
    thread.detach();
    logfire.info("reconcile: background worker started", .{});
}

fn worker(allocator: Allocator) void {
    // wait for db to be ready
    std.Thread.sleep(10 * std.time.ns_per_s);

    // PDS cache: DID → PDS endpoint URL (persists across cycles)
    var pds_cache = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = pds_cache.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        pds_cache.deinit();
    }

    var consecutive_errors: u32 = 0;

    while (true) {
        const result = runCycle(allocator, &pds_cache);
        if (result) |counts| {
            consecutive_errors = 0;
            if (counts.verified > 0 or counts.deleted > 0) {
                logfire.info("reconcile: verified {d} documents, deleted {d}", .{ counts.verified, counts.deleted });
            }
        } else |err| {
            consecutive_errors += 1;
            logfire.warn("reconcile: cycle error: {}, consecutive: {d}", .{ err, consecutive_errors });
        }

        const interval = getIntervalSecs();
        const backoff: u64 = if (consecutive_errors > 0)
            @min(interval * consecutive_errors, 3600)
        else
            interval;
        std.Thread.sleep(backoff * std.time.ns_per_s);
    }
}

const CycleCounts = struct {
    verified: usize,
    deleted: usize,
};

fn runCycle(allocator: Allocator, pds_cache: *std.StringHashMap([]const u8)) !CycleCounts {
    const span = logfire.span("reconcile.cycle", .{});
    defer span.end();

    const client = db.getClient() orelse return error.NoClient;
    const batch_size = getBatchSize();
    const reverify_days = getReverifyDays();

    // fetch docs ordered by verified_at (NULLs first = never verified = highest priority)
    // re-verify docs older than RECONCILE_REVERIFY_DAYS
    // compute cutoff timestamp in Zig (avoids strftime with parameterized modifiers)
    var batch_str: [10]u8 = undefined;
    const batch_str_val = std.fmt.bufPrint(&batch_str, "{d}", .{batch_size}) catch "50";

    const cutoff_ts = formatTimestamp(std.time.timestamp() - @as(i64, @intCast(reverify_days * 86400)));
    const cutoff = cutoff_ts.slice();

    var result = try client.query(
        \\SELECT uri, did FROM documents
        \\WHERE verified_at IS NULL
        \\   OR verified_at < ?
        \\ORDER BY verified_at ASC NULLS FIRST
        \\LIMIT ?
    ,
        &.{ cutoff, batch_str_val },
    );
    defer result.deinit();

    if (result.rows.len == 0) return .{ .verified = 0, .deleted = 0 };

    // collect URIs and DIDs from the result (copy since result owns the memory)
    const DocInfo = struct { uri: []const u8, did: []const u8 };
    var docs: std.ArrayList(DocInfo) = .empty;
    defer {
        for (docs.items) |doc| {
            allocator.free(doc.uri);
            allocator.free(doc.did);
        }
        docs.deinit(allocator);
    }

    for (result.rows) |row| {
        const uri = allocator.dupe(u8, row.text(0)) catch continue;
        const did = allocator.dupe(u8, row.text(1)) catch {
            allocator.free(uri);
            continue;
        };
        docs.append(allocator, .{ .uri = uri, .did = did }) catch {
            allocator.free(uri);
            allocator.free(did);
            continue;
        };
    }

    var verified: usize = 0;
    var deleted: usize = 0;

    // collect hashed IDs of stale docs for batch tpuf delete
    var stale_ids: std.ArrayList([32]u8) = .empty;
    defer stale_ids.deinit(allocator);

    for (docs.items) |doc| {
        const parts = parseAtUri(doc.uri) orelse {
            logfire.warn("reconcile: invalid AT-URI: {s}", .{doc.uri});
            continue;
        };

        // resolve PDS for this DID
        const pds = resolvePds(allocator, parts.did, pds_cache) orelse {
            // PDS unknown or DID deactivated — skip, don't delete
            // still update verified_at so these don't permanently clog the queue
            updateVerifiedAt(client, doc.uri);
            continue;
        };

        // check if record still exists at source
        const status = checkRecord(allocator, pds, parts.did, parts.collection, parts.rkey);

        switch (status) {
            .exists => {
                // update verified_at
                updateVerifiedAt(client, doc.uri);
                verified += 1;
            },
            .deleted => {
                // record gone — delete from turso + queue for tpuf batch delete
                indexer.deleteDocument(doc.uri);
                const hashed = tpuf.hashId(doc.uri);
                stale_ids.append(allocator, hashed) catch {};
                deleted += 1;
                logfire.info("reconcile: deleted stale document: {s}", .{doc.uri});
            },
            .error_skip => {
                // 5xx / timeout / network error — don't update verified_at, retry next cycle
            },
        }

        // rate limit: 200ms between PDS requests
        std.Thread.sleep(200 * std.time.ns_per_ms);
    }

    // batch delete from tpuf
    if (stale_ids.items.len > 0 and tpuf.isEnabled()) {
        // build slice of pointers to the hashed IDs
        var id_ptrs = allocator.alloc([]const u8, stale_ids.items.len) catch {
            logfire.warn("reconcile: alloc failed for tpuf delete batch", .{});
            return .{ .verified = verified, .deleted = deleted };
        };
        defer allocator.free(id_ptrs);

        for (stale_ids.items, 0..) |*id, i| {
            id_ptrs[i] = id;
        }

        tpuf.delete(allocator, id_ptrs) catch |err| {
            logfire.warn("reconcile: tpuf batch delete failed: {}", .{err});
        };
    }

    return .{ .verified = verified, .deleted = deleted };
}

fn updateVerifiedAt(client: *db.Client, uri: []const u8) void {
    const now = formatTimestamp(std.time.timestamp());
    client.exec(
        "UPDATE documents SET verified_at = ? WHERE uri = ?",
        &.{ now.slice(), uri },
    ) catch |err| {
        logfire.warn("reconcile: failed to update verified_at for {s}: {}", .{ uri, err });
    };
}

/// Format a unix timestamp as ISO 8601 string (same approach as embedder.zig).
const TimestampBuf = struct {
    buf: [20]u8,
    len: usize,

    fn slice(self: *const TimestampBuf) []const u8 {
        return self.buf[0..self.len];
    }
};

fn formatTimestamp(ts: i64) TimestampBuf {
    const epoch_secs: u64 = @intCast(@max(ts, 0));
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day = epoch.getDaySeconds();
    const yd = epoch.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    var result: TimestampBuf = undefined;
    const formatted = std.fmt.bufPrint(&result.buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        yd.year, md.month.numeric(), @as(u32, md.day_index) + 1,
        day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute(),
    }) catch {
        // fallback: epoch (will cause re-verify, which is safe)
        const fallback = "1970-01-01T00:00:00";
        @memcpy(result.buf[0..fallback.len], fallback);
        result.len = fallback.len;
        return result;
    };
    result.len = formatted.len;
    return result;
}

const RecordStatus = enum { exists, deleted, error_skip };

fn checkRecord(allocator: Allocator, pds: []const u8, did: []const u8, collection: []const u8, rkey: []const u8) RecordStatus {
    // build URL: {pds}/xrpc/com.atproto.repo.getRecord?repo={did}&collection={collection}&rkey={rkey}
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/xrpc/com.atproto.repo.getRecord?repo={s}&collection={s}&rkey={s}", .{ pds, did, collection, rkey }) catch {
        return .error_skip;
    };

    var http_client: http.Client = .{ .allocator = allocator };
    defer http_client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const res = http_client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_body.writer,
    }) catch {
        return .error_skip;
    };

    const status_int: u10 = @intFromEnum(res.status);
    if (status_int >= 200 and status_int < 300) return .exists;
    if (status_int == 400 or status_int == 404) return .deleted;
    // 5xx, rate limit, or unexpected status — skip
    return .error_skip;
}

/// Resolve a DID to its PDS endpoint URL via plc.directory.
/// Returns null if DID is deactivated or PDS cannot be determined.
/// Caches results in pds_cache (persists across cycles).
fn resolvePds(allocator: Allocator, did: []const u8, cache: *std.StringHashMap([]const u8)) ?[]const u8 {
    if (cache.get(did)) |pds| return pds;

    const pds = resolvePdsHttp(allocator, did) orelse return null;

    // cache with duped key + value
    const key = allocator.dupe(u8, did) catch return pds;
    cache.put(key, pds) catch {
        allocator.free(key);
    };

    return pds;
}

fn resolvePdsHttp(allocator: Allocator, did: []const u8) ?[]const u8 {
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://plc.directory/{s}", .{did}) catch return null;

    var http_client: http.Client = .{ .allocator = allocator };
    defer http_client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const res = http_client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_body.writer,
    }) catch |err| {
        logfire.warn("reconcile: PLC lookup failed for {s}: {}", .{ did, err });
        return null;
    };

    if (res.status != .ok) {
        logfire.warn("reconcile: PLC lookup {s} returned {}", .{ did, res.status });
        return null;
    }

    const body = response_body.toOwnedSlice() catch return null;
    defer allocator.free(body);

    const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();

    // look for service[].serviceEndpoint where type == "AtprotoPersonalDataServer"
    const services = parsed.value.object.get("service") orelse return null;
    if (services != .array) return null;

    for (services.array.items) |svc| {
        if (svc != .object) continue;
        const svc_type = svc.object.get("type") orelse continue;
        if (svc_type != .string) continue;
        if (!mem.eql(u8, svc_type.string, "AtprotoPersonalDataServer")) continue;
        const endpoint = svc.object.get("serviceEndpoint") orelse continue;
        if (endpoint != .string) continue;

        // dupe the endpoint — it's owned by the parsed json which we're about to free
        return allocator.dupe(u8, endpoint.string) catch null;
    }

    return null;
}
