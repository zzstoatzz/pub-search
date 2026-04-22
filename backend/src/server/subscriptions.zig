//! HTTP handlers for subscription CRUD. Paired with oauth session auth.
//!
//! Endpoints:
//!   GET    /api/me               — returns {did, handle} or 401
//!   GET    /api/subscriptions    — list the caller's subscriptions (local mirror)
//!   POST   /api/subscriptions    — create (writes to PDS + mirror)
//!   DELETE /api/subscriptions/:rkey — delete from PDS + mirror

const std = @import("std");
const Io = std.Io;
const http = std.http;
const mem = std.mem;
const json = std.json;
const Allocator = std.mem.Allocator;

const oauth = @import("../oauth.zig");
const store = @import("../state.zig");
const notifications = @import("../notifications.zig");
const db = @import("../db.zig");
const logfire = @import("logfire");

const SUBSCRIPTION_COLLECTION = notifications.SUBSCRIPTION_COLLECTION;

const ALLOWED_TRIGGER_KINDS = [_][]const u8{ "author", "publication", "platform", "tag" };

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (mem.eql(u8, h, needle)) return true;
    return false;
}

pub fn handleMe(request: *http.Server.Request, io: Io) !void {
    _ = io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const did = oauth.getSessionDid(request) orelse {
        try sendJsonStatus(request, .unauthorized, "{\"error\":\"not signed in\"}");
        return;
    };
    const session = (try store.getSession(alloc, did)) orelse {
        try sendJsonStatus(request, .unauthorized, "{\"error\":\"session expired\"}");
        return;
    };

    const body = try std.fmt.allocPrint(alloc, "{{\"did\":\"{s}\",\"handle\":\"{s}\"}}", .{ session.did, session.handle });
    try sendJson(request, body);
}

pub fn handleList(request: *http.Server.Request, io: Io) !void {
    _ = io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const did = oauth.getSessionDid(request) orelse {
        try sendJsonStatus(request, .unauthorized, "{\"error\":\"not signed in\"}");
        return;
    };

    const body = notifications.listByOwnerJson(alloc, did) catch |err| {
        std.log.warn("handleList: listByOwnerJson failed: {}", .{err});
        try sendJsonStatus(request, .internal_server_error, "{\"error\":\"failed to list subscriptions\"}");
        return;
    };
    try sendJson(request, body);
}

const CreateBody = struct {
    triggerKind: []const u8,
    triggerValue: []const u8,
    label: ?[]const u8 = null,
};

pub fn handleCreate(request: *http.Server.Request, io: Io) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const did = oauth.getSessionDid(request) orelse {
        try sendJsonStatus(request, .unauthorized, "{\"error\":\"not signed in\"}");
        return;
    };
    const session = (try store.getSession(alloc, did)) orelse {
        try sendJsonStatus(request, .unauthorized, "{\"error\":\"session expired\"}");
        return;
    };

    // read body (cap at 8KB — subscriptions are tiny)
    const body_reader = request.readerExpectContinue(&.{}) catch {
        try sendJsonStatus(request, .bad_request, "{\"error\":\"failed to read body\"}");
        return;
    };
    const body_bytes = body_reader.allocRemaining(alloc, Io.Limit.limited(8 * 1024)) catch {
        try sendJsonStatus(request, .bad_request, "{\"error\":\"failed to read body\"}");
        return;
    };

    const parsed = json.parseFromSliceLeaky(CreateBody, alloc, body_bytes, .{
        .ignore_unknown_fields = true,
    }) catch {
        try sendJsonStatus(request, .bad_request, "{\"error\":\"invalid json\"}");
        return;
    };

    // validate
    if (!contains(&ALLOWED_TRIGGER_KINDS, parsed.triggerKind)) {
        try sendJsonStatus(request, .bad_request, "{\"error\":\"invalid triggerKind\"}");
        return;
    }
    if (parsed.triggerValue.len == 0 or parsed.triggerValue.len > 512) {
        try sendJsonStatus(request, .bad_request, "{\"error\":\"triggerValue length\"}");
        return;
    }

    // destination is always the bot DMing the subscriber — implicit, not
    // something the client specifies. stored as empty-string placeholders
    // in the local mirror for schema continuity.
    const dest_kind: []const u8 = "bsky";
    const dest_value: []const u8 = "";
    const label: []const u8 = parsed.label orelse "";
    const created_at = try isoNow(alloc, io);

    // build record JSON for the PDS
    var rec_buf: std.Io.Writer.Allocating = .init(alloc);
    var jw: json.Stringify = .{ .writer = &rec_buf.writer };
    try jw.beginObject();
    try jw.objectField("$type");
    try jw.write(SUBSCRIPTION_COLLECTION);
    try jw.objectField("triggerKind");
    try jw.write(parsed.triggerKind);
    try jw.objectField("triggerValue");
    try jw.write(parsed.triggerValue);
    if (label.len > 0) {
        try jw.objectField("label");
        try jw.write(label);
    }
    try jw.objectField("createdAt");
    try jw.write(created_at);
    try jw.endObject();

    const record_json = try rec_buf.toOwnedSlice();

    // write to user's PDS
    const at_uri = oauth.createRecord(alloc, session, SUBSCRIPTION_COLLECTION, record_json) catch |err| {
        std.log.warn("handleCreate: createRecord failed: {}", .{err});
        try sendJsonStatus(request, .bad_gateway, "{\"error\":\"failed to write record to PDS\"}");
        return;
    };
    const rkey = extractRkey(at_uri) orelse {
        try sendJsonStatus(request, .bad_gateway, "{\"error\":\"PDS returned malformed at-uri\"}");
        return;
    };

    // mirror locally for fast match at ingest time
    notifications.insert(.{
        .owner_did = session.did,
        .rkey = rkey,
        .trigger_kind = parsed.triggerKind,
        .trigger_value = parsed.triggerValue,
        .destination_kind = dest_kind,
        .destination_value = dest_value,
        .secret = "",
        .label = label,
        .created_at = created_at,
    }) catch |err| {
        std.log.warn("handleCreate: local mirror insert failed: {}", .{err});
        // don't rollback the PDS write — the firehose will eventually reconcile
    };

    const out = try std.fmt.allocPrint(alloc, "{{\"ok\":true,\"rkey\":\"{s}\",\"uri\":\"{s}\"}}", .{ rkey, at_uri });
    try sendJson(request, out);
}

/// GET /api/my-publications — list the publications the authenticated
/// user is *subscribed to*, via their `site.standard.graph.subscription`
/// records. That's standard.site's canonical "user follows publication"
/// record — the signal we hook into so "turn on notifications" maps
/// cleanly onto publications the user already cares about.
///
/// For each subscription record we pluck the `publication` at-uri and
/// try to resolve the publication's metadata (name/url) from pub-search's
/// local mirror. If it's not in the index yet, we still return the at-uri
/// so the UI can show it.
pub fn handleMyPublications(request: *http.Server.Request, io: Io) !void {
    _ = io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const did = oauth.getSessionDid(request) orelse {
        try sendJsonStatus(request, .unauthorized, "{\"error\":\"not signed in\"}");
        return;
    };
    const session = (try store.getSession(alloc, did)) orelse {
        try sendJsonStatus(request, .unauthorized, "{\"error\":\"session expired\"}");
        return;
    };

    const url = try std.fmt.allocPrint(alloc, "{s}/xrpc/com.atproto.repo.listRecords?repo={s}&collection=site.standard.graph.subscription&limit=100", .{
        session.pds_url, session.did,
    });
    logfire.info("handleMyPublications: did={s} pds={s}", .{ session.did, session.pds_url });

    const body = oauth.httpGet(alloc, url) catch |err| {
        logfire.warn("handleMyPublications: listRecords failed: {}", .{err});
        try sendJsonStatus(request, .bad_gateway, "{\"error\":\"failed to fetch subscriptions from PDS\"}");
        return;
    };
    logfire.info("handleMyPublications: body_bytes={d} preview={s}", .{
        body.len,
        body[0..@min(body.len, 120)],
    });

    const parsed = json.parseFromSlice(json.Value, alloc, body, .{}) catch {
        logfire.warn("handleMyPublications: json parse failed, body_preview={s}", .{body[0..@min(body.len, 200)]});
        try sendJsonStatus(request, .bad_gateway, "{\"error\":\"PDS returned invalid json\"}");
        return;
    };
    defer parsed.deinit();

    const records = parsed.value.object.get("records") orelse {
        logfire.info("handleMyPublications: no 'records' key in response", .{});
        try sendJson(request, "[]");
        return;
    };
    if (records != .array) {
        logfire.info("handleMyPublications: 'records' is not an array (kind={t})", .{records});
        try sendJson(request, "[]");
        return;
    }
    logfire.info("handleMyPublications: returning {d} records", .{records.array.items.len});

    const local = db.getLocalDbRaw();

    var out: std.Io.Writer.Allocating = .init(alloc);
    var jw: json.Stringify = .{ .writer = &out.writer };
    try jw.beginArray();
    for (records.array.items) |rec| {
        if (rec != .object) continue;
        const val = rec.object.get("value") orelse continue;
        if (val != .object) continue;
        const pub_v = val.object.get("publication") orelse continue;
        if (pub_v != .string) continue;
        const pub_uri = pub_v.string;

        // enrich from local publications mirror — name + base_path
        var name: []const u8 = "";
        var base_path: []const u8 = "";
        if (local) |l| {
            if (l.query("SELECT name, base_path FROM publications WHERE uri = ?", .{pub_uri})) |q| {
                var rows = q;
                defer rows.deinit();
                if (rows.next()) |row| {
                    // dupe into arena — underlying slice dies with rows.deinit
                    name = alloc.dupe(u8, row.text(0)) catch "";
                    base_path = alloc.dupe(u8, row.text(1)) catch "";
                }
            } else |_| {}
        }

        try jw.beginObject();
        try jw.objectField("uri");
        try jw.write(pub_uri);
        if (name.len > 0) {
            try jw.objectField("name");
            try jw.write(name);
        }
        if (base_path.len > 0) {
            const pub_url = try std.fmt.allocPrint(alloc, "https://{s}", .{base_path});
            try jw.objectField("url");
            try jw.write(pub_url);
        }
        try jw.endObject();
    }
    try jw.endArray();

    const result = try out.toOwnedSlice();
    try sendJson(request, result);
}

pub fn handleTestFire(request: *http.Server.Request, rkey: []const u8, io: Io) !void {
    _ = io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const did = oauth.getSessionDid(request) orelse {
        try sendJsonStatus(request, .unauthorized, "{\"error\":\"not signed in\"}");
        return;
    };

    notifications.testFire(alloc, did, rkey) catch |err| {
        const msg = switch (err) {
            error.NotFound => "{\"error\":\"subscription not found\"}",
            else => "{\"error\":\"test fire failed\"}",
        };
        try sendJsonStatus(request, .bad_request, msg);
        return;
    };
    try sendJson(request, "{\"ok\":true,\"note\":\"delivery enqueued — check bsky DMs\"}");
}

pub fn handleDelete(request: *http.Server.Request, rkey: []const u8, io: Io) !void {
    _ = io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const did = oauth.getSessionDid(request) orelse {
        try sendJsonStatus(request, .unauthorized, "{\"error\":\"not signed in\"}");
        return;
    };
    const session = (try store.getSession(alloc, did)) orelse {
        try sendJsonStatus(request, .unauthorized, "{\"error\":\"session expired\"}");
        return;
    };

    // delete from PDS first so partial failure leaves us with a dangling
    // local row the user can re-sweep; better than a dangling PDS record.
    oauth.deleteRecord(alloc, session, SUBSCRIPTION_COLLECTION, rkey) catch |err| {
        std.log.warn("handleDelete: PDS deleteRecord failed: {}", .{err});
        try sendJsonStatus(request, .bad_gateway, "{\"error\":\"failed to delete record on PDS\"}");
        return;
    };
    notifications.deleteByRkey(session.did, rkey) catch |err| {
        std.log.warn("handleDelete: local deleteByRkey failed: {}", .{err});
    };

    try sendJson(request, "{\"ok\":true}");
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn extractRkey(at_uri: []const u8) ?[]const u8 {
    const idx = mem.lastIndexOfScalar(u8, at_uri, '/') orelse return null;
    if (idx + 1 >= at_uri.len) return null;
    return at_uri[idx + 1 ..];
}

fn isoNow(alloc: Allocator, io: Io) ![]const u8 {
    // ISO-8601 UTC timestamp for the `createdAt` field (matches lexicon format: datetime)
    const now_secs: i64 = @intCast(@divTrunc(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now_secs) };
    const day = epoch_secs.getDaySeconds();
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const md = year_day.calculateMonthDay();
    return try std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        @intFromEnum(md.month),
        md.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    });
}

fn sendJson(request: *http.Server.Request, body: []const u8) !void {
    try sendJsonStatus(request, .ok, body);
}

fn sendJsonStatus(request: *http.Server.Request, status: http.Status, body: []const u8) !void {
    try request.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = oauth.config().frontend_origin },
            .{ .name = "access-control-allow-credentials", .value = "true" },
            .{ .name = "vary", .value = "origin" },
        },
    });
}
