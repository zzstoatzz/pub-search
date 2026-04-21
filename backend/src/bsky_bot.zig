//! bsky DM sender for the pub-search bot account.
//!
//! The bot (@pub-search.waow.tech) authenticates with an app password,
//! caches its session (accessJwt + refreshJwt + PDS URL), and sends DMs
//! via `chat.bsky.convo.*` proxied through its PDS.
//!
//! Why a bot instead of each user DMing themselves: bsky chat convos
//! require at least two distinct members, so users can't "DM themselves"
//! through the chat service. The bot is the second member.
//!
//! Session management is lazy + self-healing: login on first use, retry
//! once on 401 after clearing the session.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const json = std.json;
const Allocator = std.mem.Allocator;
const zat = @import("zat");
const logfire = @import("logfire");

const BSKY_CHAT_PROXY = "did:web:api.bsky.chat#bsky_chat";

var cfg_io: Io = undefined;
var cfg_alloc: Allocator = undefined;
var cfg_handle: []const u8 = "";
var cfg_password: []const u8 = "";
var cfg_set = false;

var mutex: Io.Mutex = .init;
// cached state (heap-owned, guarded by mutex)
var cached_pds: ?[]u8 = null;
var cached_access: ?[]u8 = null;
var cached_refresh: ?[]u8 = null;

pub fn init(alloc: Allocator, io: Io, handle: []const u8, password: []const u8) void {
    cfg_alloc = alloc;
    cfg_io = io;
    cfg_handle = handle;
    cfg_password = password;
    cfg_set = true;
}

pub fn isConfigured() bool {
    return cfg_set and cfg_handle.len > 0 and cfg_password.len > 0;
}

/// Send a DM from the bot to `to_did` with the given text. Handles login
/// and 401 recovery transparently.
pub fn sendDm(arena: Allocator, to_did: []const u8, text: []const u8) !void {
    if (!isConfigured()) return error.BotNotConfigured;

    const convo_id = try callWithRetry(arena, to_did, null);
    _ = try callWithRetry(arena, convo_id, text);
}

/// Shared retry wrapper. If `text` is null, resolves a convo; otherwise
/// sends `text`. Returns the convo_id for the resolve case, empty for send.
fn callWithRetry(arena: Allocator, arg: []const u8, text: ?[]const u8) ![]const u8 {
    var attempted_relogin = false;
    while (true) {
        try ensureSession(arena);
        const sn = try snapshot(arena);

        const result = if (text) |t|
            sendMessage(arena, sn, arg, t)
        else
            getConvoForMembers(arena, sn, arg);

        if (result) |ok| {
            return ok;
        } else |err| {
            if (err == error.Unauthorized and !attempted_relogin) {
                logfire.info("bsky_bot: 401 — clearing cached session and retrying", .{});
                clearSession();
                attempted_relogin = true;
                continue;
            }
            return err;
        }
    }
}

// ---------------------------------------------------------------------------
// session management
// ---------------------------------------------------------------------------

const Snapshot = struct { pds: []const u8, access: []const u8 };

fn snapshot(arena: Allocator) !Snapshot {
    mutex.lockUncancelable(cfg_io);
    defer mutex.unlock(cfg_io);
    const pds = cached_pds orelse return error.NoSession;
    const access = cached_access orelse return error.NoSession;
    return .{
        .pds = try arena.dupe(u8, pds),
        .access = try arena.dupe(u8, access),
    };
}

fn ensureSession(arena: Allocator) !void {
    {
        mutex.lockUncancelable(cfg_io);
        defer mutex.unlock(cfg_io);
        if (cached_access != null and cached_pds != null) return;
    }
    try login(arena);
}

fn clearSession() void {
    mutex.lockUncancelable(cfg_io);
    defer mutex.unlock(cfg_io);
    if (cached_access) |a| {
        cfg_alloc.free(a);
        cached_access = null;
    }
    if (cached_refresh) |r| {
        cfg_alloc.free(r);
        cached_refresh = null;
    }
    // keep cached_pds so we don't re-resolve on every re-login
}

fn login(arena: Allocator) !void {
    const pds_url = try resolvePds(arena);

    const body = try std.fmt.allocPrint(arena,
        \\{{"identifier":"{s}","password":"{s}"}}
    , .{ cfg_handle, cfg_password });

    const result = try httpPost(arena, pds_url, "/xrpc/com.atproto.server.createSession", body, null, false);
    if (result.status != .ok) {
        logfire.err("bsky_bot: createSession failed status={t} body={s}", .{ result.status, result.body[0..@min(result.body.len, 400)] });
        return error.LoginFailed;
    }
    const parsed = try json.parseFromSlice(json.Value, arena, result.body, .{});
    defer parsed.deinit();
    const access_v = parsed.value.object.get("accessJwt") orelse return error.MissingAccessJwt;
    const refresh_v = parsed.value.object.get("refreshJwt") orelse return error.MissingRefreshJwt;
    if (access_v != .string or refresh_v != .string) return error.BadLoginResponse;

    mutex.lockUncancelable(cfg_io);
    defer mutex.unlock(cfg_io);
    if (cached_pds) |p| cfg_alloc.free(p);
    if (cached_access) |a| cfg_alloc.free(a);
    if (cached_refresh) |r| cfg_alloc.free(r);
    cached_pds = try cfg_alloc.dupe(u8, pds_url);
    cached_access = try cfg_alloc.dupe(u8, access_v.string);
    cached_refresh = try cfg_alloc.dupe(u8, refresh_v.string);
    logfire.info("bsky_bot: logged in handle={s} pds={s}", .{ cfg_handle, pds_url });
}

fn resolvePds(arena: Allocator) ![]const u8 {
    var hres = zat.HandleResolver.init(cfg_io, arena);
    defer hres.deinit();
    const parsed_handle = zat.Handle.parse(cfg_handle) orelse return error.InvalidHandle;
    const did = try hres.resolve(parsed_handle);

    var dres = zat.DidResolver.init(cfg_io, arena);
    defer dres.deinit();
    var did_doc = try dres.resolve(zat.Did.parse(did) orelse return error.InvalidDid);
    defer did_doc.deinit();
    return try arena.dupe(u8, did_doc.pdsEndpoint() orelse return error.NoPds);
}

// ---------------------------------------------------------------------------
// xrpc calls
// ---------------------------------------------------------------------------

fn getConvoForMembers(arena: Allocator, sn: Snapshot, to_did: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(arena, "/xrpc/chat.bsky.convo.getConvoForMembers?members={s}", .{to_did});
    const result = try httpGet(arena, sn.pds, path, sn.access, true);
    if (result.status == .unauthorized) return error.Unauthorized;
    if (result.status != .ok) {
        logfire.err("bsky_bot: getConvoForMembers status={t} body={s}", .{ result.status, result.body[0..@min(result.body.len, 400)] });
        return error.FetchFailed;
    }
    const parsed = try json.parseFromSlice(json.Value, arena, result.body, .{});
    defer parsed.deinit();
    const convo = parsed.value.object.get("convo") orelse return error.MissingConvo;
    if (convo != .object) return error.MissingConvo;
    const id = convo.object.get("id") orelse return error.MissingConvoId;
    if (id != .string) return error.MissingConvoId;
    return try arena.dupe(u8, id.string);
}

fn sendMessage(arena: Allocator, sn: Snapshot, convo_id: []const u8, text: []const u8) ![]const u8 {
    var body_buf: std.Io.Writer.Allocating = .init(arena);
    var jw: json.Stringify = .{ .writer = &body_buf.writer };
    try jw.beginObject();
    try jw.objectField("convoId");
    try jw.write(convo_id);
    try jw.objectField("message");
    try jw.beginObject();
    try jw.objectField("text");
    try jw.write(text);
    try jw.endObject();
    try jw.endObject();
    const body = try body_buf.toOwnedSlice();

    const result = try httpPost(arena, sn.pds, "/xrpc/chat.bsky.convo.sendMessage", body, sn.access, true);
    if (result.status == .unauthorized) return error.Unauthorized;
    if (result.status != .ok) {
        logfire.err("bsky_bot: sendMessage status={t} body={s}", .{ result.status, result.body[0..@min(result.body.len, 400)] });
        return error.FetchFailed;
    }
    return "";
}

// ---------------------------------------------------------------------------
// HTTP helpers (bearer + optional chat-proxy)
// ---------------------------------------------------------------------------

const HttpResult = struct { status: http.Status, body: []u8 };

fn buildHeaders(access: ?[]const u8, chat_proxy: bool, auth_buf: []u8, out: *[2]http.Header) !u8 {
    var n: u8 = 0;
    if (access) |a| {
        const auth = try std.fmt.bufPrint(auth_buf, "Bearer {s}", .{a});
        out[n] = .{ .name = "Authorization", .value = auth };
        n += 1;
    }
    if (chat_proxy) {
        out[n] = .{ .name = "atproto-proxy", .value = BSKY_CHAT_PROXY };
        n += 1;
    }
    return n;
}

fn httpGet(arena: Allocator, base: []const u8, path: []const u8, access: []const u8, chat_proxy: bool) !HttpResult {
    const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ base, path });

    var auth_buf: [4096]u8 = undefined;
    var hdrs: [2]http.Header = undefined;
    const n = try buildHeaders(access, chat_proxy, &auth_buf, &hdrs);

    var client: http.Client = .{ .allocator = arena, .io = cfg_io };
    defer client.deinit();

    var req = try client.request(.GET, try std.Uri.parse(url), .{
        .extra_headers = hdrs[0..n],
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    });
    defer req.deinit();

    try req.sendBodiless();
    var redirect_buf: [1]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    var aw: std.Io.Writer.Allocating = .init(arena);
    const reader = response.reader(&.{});
    _ = reader.streamRemaining(&aw.writer) catch {};
    return .{ .status = response.head.status, .body = try aw.toOwnedSlice() };
}

fn httpPost(arena: Allocator, base: []const u8, path: []const u8, body: []const u8, access: ?[]const u8, chat_proxy: bool) !HttpResult {
    const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ base, path });

    var auth_buf: [4096]u8 = undefined;
    var hdrs: [2]http.Header = undefined;
    const n = try buildHeaders(access, chat_proxy, &auth_buf, &hdrs);

    var client: http.Client = .{ .allocator = arena, .io = cfg_io };
    defer client.deinit();

    var req = try client.request(.POST, try std.Uri.parse(url), .{
        .extra_headers = hdrs[0..n],
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .{ .override = "identity" },
        },
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(body);
    try body_writer.end();
    try req.connection.?.flush();

    var redirect_buf: [1]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    var aw: std.Io.Writer.Allocating = .init(arena);
    const reader = response.reader(&.{});
    _ = reader.streamRemaining(&aw.writer) catch {};
    return .{ .status = response.head.status, .body = try aw.toOwnedSlice() };
}
