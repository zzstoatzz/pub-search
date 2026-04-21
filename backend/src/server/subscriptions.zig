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

const SUBSCRIPTION_COLLECTION = notifications.SUBSCRIPTION_COLLECTION;

const ALLOWED_TRIGGER_KINDS = [_][]const u8{ "author", "publication", "platform", "tag" };
const ALLOWED_DEST_KINDS = [_][]const u8{"bsky"};

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
    destinationKind: []const u8,
    destinationValue: []const u8,
    secret: ?[]const u8 = null,
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
    if (!contains(&ALLOWED_DEST_KINDS, parsed.destinationKind)) {
        try sendJsonStatus(request, .bad_request, "{\"error\":\"invalid destinationKind\"}");
        return;
    }
    if (parsed.triggerValue.len == 0 or parsed.triggerValue.len > 512) {
        try sendJsonStatus(request, .bad_request, "{\"error\":\"triggerValue length\"}");
        return;
    }
    if (parsed.destinationValue.len == 0 or parsed.destinationValue.len > 512) {
        try sendJsonStatus(request, .bad_request, "{\"error\":\"destinationValue length\"}");
        return;
    }
    // for bsky: resolve handle → DID at create time if needed, so we store
    // a stable identifier the chat.convo.getConvoForMembers call can use.
    var resolved_dest = parsed.destinationValue;
    if (mem.eql(u8, parsed.destinationKind, "bsky") and !mem.startsWith(u8, resolved_dest, "did:")) {
        const zat = @import("zat");
        var resolver = zat.HandleResolver.init(io, alloc);
        defer resolver.deinit();
        const parsed_handle = zat.Handle.parse(resolved_dest) orelse {
            try sendJsonStatus(request, .bad_request, "{\"error\":\"invalid bsky handle\"}");
            return;
        };
        resolved_dest = resolver.resolve(parsed_handle) catch {
            try sendJsonStatus(request, .bad_request, "{\"error\":\"could not resolve bsky handle\"}");
            return;
        };
    }

    const secret: []const u8 = ""; // no longer used; retained in schema for future signed destinations
    _ = parsed.secret;
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
    try jw.objectField("destinationKind");
    try jw.write(parsed.destinationKind);
    try jw.objectField("destinationValue");
    try jw.write(resolved_dest);
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
        .destination_kind = parsed.destinationKind,
        .destination_value = resolved_dest,
        .secret = secret,
        .label = label,
        .created_at = created_at,
    }) catch |err| {
        std.log.warn("handleCreate: local mirror insert failed: {}", .{err});
        // don't rollback the PDS write — the firehose will eventually reconcile
    };

    const out = try std.fmt.allocPrint(alloc, "{{\"ok\":true,\"rkey\":\"{s}\",\"uri\":\"{s}\"}}", .{ rkey, at_uri });
    try sendJson(request, out);
}

/// GET /api/my-publications — list the authenticated user's
/// site.standard.publication records by hitting their PDS directly
/// (records are public; no DPoP needed). This is the source of truth
/// for the toggle list in the subscriptions UI.
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

    const url = try std.fmt.allocPrint(alloc, "{s}/xrpc/com.atproto.repo.listRecords?repo={s}&collection=site.standard.publication&limit=100", .{
        session.pds_url, session.did,
    });

    const body = oauth.httpGet(alloc, url) catch |err| {
        std.log.warn("handleMyPublications: listRecords failed: {}", .{err});
        try sendJsonStatus(request, .bad_gateway, "{\"error\":\"failed to fetch publications from PDS\"}");
        return;
    };

    const parsed = json.parseFromSlice(json.Value, alloc, body, .{}) catch {
        try sendJsonStatus(request, .bad_gateway, "{\"error\":\"PDS returned invalid json\"}");
        return;
    };
    defer parsed.deinit();

    const records = parsed.value.object.get("records") orelse {
        try sendJson(request, "[]");
        return;
    };
    if (records != .array) {
        try sendJson(request, "[]");
        return;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    var jw: json.Stringify = .{ .writer = &out.writer };
    try jw.beginArray();
    for (records.array.items) |rec| {
        if (rec != .object) continue;
        const uri_v = rec.object.get("uri") orelse continue;
        if (uri_v != .string) continue;
        const val = rec.object.get("value") orelse continue;
        if (val != .object) continue;

        try jw.beginObject();
        try jw.objectField("uri");
        try jw.write(uri_v.string);
        if (val.object.get("name")) |n| if (n == .string) {
            try jw.objectField("name");
            try jw.write(n.string);
        };
        if (val.object.get("url")) |u| if (u == .string) {
            try jw.objectField("url");
            try jw.write(u.string);
        };
        if (val.object.get("description")) |d| if (d == .string) {
            try jw.objectField("description");
            try jw.write(d.string);
        };
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
            error.UnsupportedDestination => "{\"error\":\"cannot test-fire this destination kind\"}",
            else => "{\"error\":\"test fire failed\"}",
        };
        try sendJsonStatus(request, .bad_request, msg);
        return;
    };
    try sendJson(request, "{\"ok\":true,\"note\":\"delivery enqueued — check your webhook receiver\"}");
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
