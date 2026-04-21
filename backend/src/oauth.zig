//! OAuth client + authenticated PDS request helpers.
//!
//! lifted from ken/backend/src/oauth.zig (which in turn was lifted from
//! pollz/backend/src/http.zig). the OAuth flow itself (PAR, token exchange,
//! DPoP nonce retry, token refresh) is mechanical protocol work and there's
//! no value in re-inventing it. what differs here:
//!   - scope: `atproto repo:tech.waow.pub-search.subscription`
//!   - cookie name: pubsearch_session
//!   - redirect post-callback: /subscriptions.html
//!
//! reference: https://atproto.com/specs/oauth

const std = @import("std");
const Io = std.Io;
const http = std.http;
const mem = std.mem;
const json = std.json;
const Allocator = mem.Allocator;

const zat = @import("zat");
const zat_oauth = zat.oauth;
const store = @import("state.zig");

// `transition:chat.bsky` grants access to chat.bsky.* xrpc endpoints
// (proxied through the user's PDS to did:web:api.bsky.chat). needed so
// subscribers can receive DM deliveries on their own behalf.
pub const SCOPE = "atproto repo:tech.waow.pub-search.subscription transition:chat.bsky";

pub const Config = struct {
    io: Io,
    client_id: []const u8,
    redirect_uri: []const u8,
    frontend_origin: []const u8,
    client_key_hex: []const u8, // 64 hex chars (32 bytes p256 private)
};

var cfg: Config = undefined;
var cfg_set: bool = false;

pub fn init(c: Config) void {
    cfg = c;
    cfg_set = true;
}

pub fn config() Config {
    std.debug.assert(cfg_set);
    return cfg;
}

pub fn getClientKeypair() !zat.Keypair {
    if (cfg.client_key_hex.len != 64) return error.InvalidClientKey;
    var key_bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&key_bytes, cfg.client_key_hex) catch return error.InvalidClientKey;
    return zat.Keypair.fromSecretKey(.p256, key_bytes);
}

pub fn keypairFromHex(hex: []const u8) !zat.Keypair {
    if (hex.len != 64) return error.InvalidKeyHex;
    var key_bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&key_bytes, hex) catch return error.InvalidKeyHex;
    return zat.Keypair.fromSecretKey(.p256, key_bytes);
}

// ---------------------------------------------------------------------------
// basic HTTP helpers
// ---------------------------------------------------------------------------

pub fn httpGet(alloc: Allocator, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = alloc, .io = cfg.io };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    }) catch {
        aw.deinit();
        return error.FetchFailed;
    };
    if (result.status != .ok) {
        aw.deinit();
        return error.FetchFailed;
    }
    return aw.toOwnedSlice() catch error.FetchFailed;
}

pub const HttpResult = struct {
    status: http.Status,
    body: []u8,
    dpop_nonce: ?[]const u8,
};

pub fn doPost(
    alloc: Allocator,
    url: []const u8,
    payload: []const u8,
    extra_headers: []const http.Header,
) !HttpResult {
    var client: std.http.Client = .{ .allocator = alloc, .io = cfg.io };
    defer client.deinit();

    var req = try client.request(.POST, try std.Uri.parse(url), .{
        .extra_headers = extra_headers,
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
            .accept_encoding = .{ .override = "identity" },
        },
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload.len };
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    try req.connection.?.flush();

    var redirect_buf: [1]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.FetchFailed;

    var dpop_nonce: ?[]const u8 = null;
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "dpop-nonce")) {
            dpop_nonce = try alloc.dupe(u8, h.value);
            break;
        }
    }

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const reader = response.reader(&.{});
    _ = reader.streamRemaining(&aw.writer) catch {
        aw.deinit();
        return error.FetchFailed;
    };
    const resp_body = aw.toOwnedSlice() catch return error.FetchFailed;

    return .{ .status = response.head.status, .body = resp_body, .dpop_nonce = dpop_nonce };
}

pub fn isDpopNonceError(status: http.Status, body: []const u8) bool {
    if (status != .bad_request and status != .unauthorized) return false;
    return mem.indexOf(u8, body, "use_dpop_nonce") != null;
}

pub fn isWwwAuthNonceError(status: http.Status, www_auth: ?[]const u8) bool {
    if (status != .unauthorized) return false;
    const h = www_auth orelse return false;
    return mem.indexOf(u8, h, "use_dpop_nonce") != null;
}

// ---------------------------------------------------------------------------
// oauth metadata discovery
// ---------------------------------------------------------------------------

pub fn fetchAuthServerUrl(alloc: Allocator, pds_url: []const u8) ![]const u8 {
    const url = try std.fmt.allocPrint(alloc, "{s}/.well-known/oauth-protected-resource", .{pds_url});
    defer alloc.free(url);

    const body = try httpGet(alloc, url);
    defer alloc.free(body);

    const parsed = try json.parseFromSlice(json.Value, alloc, body, .{});
    defer parsed.deinit();

    const servers = parsed.value.object.get("authorization_servers") orelse return error.NoAuthServers;
    if (servers != .array or servers.array.items.len == 0) return error.NoAuthServers;
    const first = servers.array.items[0];
    if (first != .string) return error.NoAuthServers;
    return alloc.dupe(u8, first.string);
}

pub fn fetchAuthServerMeta(alloc: Allocator, authserver_url: []const u8) !json.Parsed(json.Value) {
    const url = try std.fmt.allocPrint(alloc, "{s}/.well-known/oauth-authorization-server", .{authserver_url});
    defer alloc.free(url);
    const body = try httpGet(alloc, url);
    return json.parseFromSlice(json.Value, alloc, body, .{});
}

pub fn jsonGetString(value: json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const v = value.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

// ---------------------------------------------------------------------------
// PAR + token exchange + refresh
// ---------------------------------------------------------------------------

pub const ParResult = struct { request_uri: []const u8, dpop_nonce: []const u8 };
pub const ParParams = struct {
    par_url: []const u8,
    authserver_url: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    scope: []const u8,
    state: []const u8,
    pkce_challenge: []const u8,
    handle: []const u8,
    client_keypair: *const zat.Keypair,
    dpop_keypair: *const zat.Keypair,
};

pub fn sendParRequest(alloc: Allocator, params: ParParams) !ParResult {
    const client_assertion = try zat_oauth.createClientAssertion(
        alloc,
        cfg.io,
        params.client_keypair,
        params.client_id,
        params.authserver_url,
    );
    defer alloc.free(client_assertion);

    const dpop_proof = try zat_oauth.createDpopProof(
        alloc,
        cfg.io,
        params.dpop_keypair,
        "POST",
        params.par_url,
        null,
        null,
    );
    defer alloc.free(dpop_proof);

    const form_params = [_][2][]const u8{
        .{ "response_type", "code" },
        .{ "code_challenge", params.pkce_challenge },
        .{ "code_challenge_method", "S256" },
        .{ "redirect_uri", params.redirect_uri },
        .{ "scope", params.scope },
        .{ "state", params.state },
        .{ "login_hint", params.handle },
        .{ "client_id", params.client_id },
        .{ "client_assertion_type", "urn:ietf:params:oauth:client-assertion-type:jwt-bearer" },
        .{ "client_assertion", client_assertion },
    };
    const form_body = try zat_oauth.formEncode(alloc, &form_params);
    defer alloc.free(form_body);

    var result = try doPost(alloc, params.par_url, form_body, &.{
        .{ .name = "DPoP", .value = dpop_proof },
    });

    if (isDpopNonceError(result.status, result.body)) {
        const nonce = result.dpop_nonce orelse return error.MissingDpopNonce;
        alloc.free(result.body);
        const proof2 = try zat_oauth.createDpopProof(
            alloc,
            cfg.io,
            params.dpop_keypair,
            "POST",
            params.par_url,
            nonce,
            null,
        );
        defer alloc.free(proof2);
        result = try doPost(alloc, params.par_url, form_body, &.{
            .{ .name = "DPoP", .value = proof2 },
        });
    }
    defer alloc.free(result.body);

    if (result.status != .ok and result.status != .created) {
        std.log.warn("PAR error ({t}): {s}", .{ result.status, result.body });
        return error.ParFailed;
    }

    const parsed = try json.parseFromSlice(json.Value, alloc, result.body, .{});
    defer parsed.deinit();
    const request_uri = jsonGetString(parsed.value, "request_uri") orelse return error.MissingRequestUri;

    return .{
        .request_uri = try alloc.dupe(u8, request_uri),
        .dpop_nonce = if (result.dpop_nonce) |n| try alloc.dupe(u8, n) else try alloc.dupe(u8, ""),
    };
}

pub const TokenResult = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    sub: []const u8,
    dpop_nonce: []const u8,
};

pub const TokenParams = struct {
    token_url: []const u8,
    authserver_url: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    code: []const u8,
    pkce_verifier: []const u8,
    client_keypair: *const zat.Keypair,
    dpop_keypair: *const zat.Keypair,
    dpop_nonce: []const u8,
};

pub fn sendTokenRequest(alloc: Allocator, params: TokenParams) !TokenResult {
    const client_assertion = try zat_oauth.createClientAssertion(
        alloc,
        cfg.io,
        params.client_keypair,
        params.client_id,
        params.authserver_url,
    );
    defer alloc.free(client_assertion);

    const dpop_proof = try zat_oauth.createDpopProof(
        alloc,
        cfg.io,
        params.dpop_keypair,
        "POST",
        params.token_url,
        if (params.dpop_nonce.len > 0) params.dpop_nonce else null,
        null,
    );
    defer alloc.free(dpop_proof);

    const form_params = [_][2][]const u8{
        .{ "grant_type", "authorization_code" },
        .{ "code", params.code },
        .{ "redirect_uri", params.redirect_uri },
        .{ "code_verifier", params.pkce_verifier },
        .{ "client_id", params.client_id },
        .{ "client_assertion_type", "urn:ietf:params:oauth:client-assertion-type:jwt-bearer" },
        .{ "client_assertion", client_assertion },
    };
    const form_body = try zat_oauth.formEncode(alloc, &form_params);
    defer alloc.free(form_body);

    var result = try doPost(alloc, params.token_url, form_body, &.{
        .{ .name = "DPoP", .value = dpop_proof },
    });

    if (isDpopNonceError(result.status, result.body)) {
        const nonce = result.dpop_nonce orelse return error.MissingDpopNonce;
        alloc.free(result.body);
        const proof2 = try zat_oauth.createDpopProof(
            alloc,
            cfg.io,
            params.dpop_keypair,
            "POST",
            params.token_url,
            nonce,
            null,
        );
        defer alloc.free(proof2);
        result = try doPost(alloc, params.token_url, form_body, &.{
            .{ .name = "DPoP", .value = proof2 },
        });
    }
    defer alloc.free(result.body);

    if (result.status != .ok) {
        std.log.warn("token exchange error ({t}): {s}", .{ result.status, result.body });
        return error.TokenExchangeFailed;
    }

    const parsed = try json.parseFromSlice(json.Value, alloc, result.body, .{});
    defer parsed.deinit();

    return .{
        .access_token = try alloc.dupe(u8, jsonGetString(parsed.value, "access_token") orelse return error.MissingAccessToken),
        .refresh_token = try alloc.dupe(u8, jsonGetString(parsed.value, "refresh_token") orelse return error.MissingRefreshToken),
        .sub = try alloc.dupe(u8, jsonGetString(parsed.value, "sub") orelse return error.MissingSub),
        .dpop_nonce = if (result.dpop_nonce) |n| try alloc.dupe(u8, n) else try alloc.dupe(u8, ""),
    };
}

// ---------------------------------------------------------------------------
// authenticated PDS request (DPoP + nonce retry + 401 refresh)
// ---------------------------------------------------------------------------

pub const PdsError = error{
    Unauthorized,
    FetchFailed,
    InvalidSessionKey,
    AuthHeaderTooLong,
    DpopNonceRetryExhausted,
    OutOfMemory,
};

pub fn pdsAuthedRequest(
    alloc: Allocator,
    session: store.Session,
    method_str: []const u8,
    path: []const u8,
    body: ?[]const u8,
    content_type: []const u8,
    extra_headers: []const http.Header,
) ![]u8 {
    const dpop_keypair = keypairFromHex(session.dpop_private_key) catch return error.InvalidSessionKey;

    var access_token_buf: [2048]u8 = undefined;
    @memcpy(access_token_buf[0..session.access_token.len], session.access_token);
    var access_token_len = session.access_token.len;
    var refreshed = false;

    for (0..2) |attempt| {
        const access_token = access_token_buf[0..access_token_len];
        const url = try std.fmt.allocPrint(alloc, "{s}{s}", .{ session.pds_url, path });
        defer alloc.free(url);

        const ath = try zat_oauth.accessTokenHash(alloc, access_token);
        defer alloc.free(ath);

        var nonce: ?[]const u8 = if (session.dpop_pds_nonce.len > 0) session.dpop_pds_nonce else null;

        const inner = for (0..2) |_| {
            const dpop_proof = try zat_oauth.createDpopProof(alloc, cfg.io, &dpop_keypair, method_str, url, nonce, ath);
            defer alloc.free(dpop_proof);

            var auth_hdr_buf: [4096]u8 = undefined;
            const auth_header = std.fmt.bufPrint(&auth_hdr_buf, "DPoP {s}", .{access_token}) catch return error.AuthHeaderTooLong;

            const http_method: http.Method = if (mem.eql(u8, method_str, "POST")) .POST else .GET;

            var client: std.http.Client = .{ .allocator = alloc, .io = cfg.io };
            defer client.deinit();

            // concat auth + dpop + caller-provided extra headers
            var hdrs_buf: [16]http.Header = undefined;
            hdrs_buf[0] = .{ .name = "Authorization", .value = auth_header };
            hdrs_buf[1] = .{ .name = "DPoP", .value = dpop_proof };
            var n_hdrs: usize = 2;
            for (extra_headers) |h| {
                if (n_hdrs >= hdrs_buf.len) break;
                hdrs_buf[n_hdrs] = h;
                n_hdrs += 1;
            }
            var req = try client.request(http_method, try std.Uri.parse(url), .{
                .extra_headers = hdrs_buf[0..n_hdrs],
                .headers = .{
                    .content_type = .{ .override = content_type },
                    .accept_encoding = .{ .override = "identity" },
                },
            });
            defer req.deinit();

            if (body) |b| {
                req.transfer_encoding = .{ .content_length = b.len };
                var body_writer = try req.sendBodyUnflushed(&.{});
                try body_writer.writer.writeAll(b);
                try body_writer.end();
                try req.connection.?.flush();
            } else {
                try req.sendBodiless();
            }

            var redirect_buf: [1]u8 = undefined;
            var response = req.receiveHead(&redirect_buf) catch return error.FetchFailed;

            var new_nonce: ?[]const u8 = null;
            var www_auth: ?[]const u8 = null;
            var hit = response.head.iterateHeaders();
            while (hit.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "dpop-nonce")) {
                    new_nonce = h.value;
                } else if (std.ascii.eqlIgnoreCase(h.name, "www-authenticate")) {
                    www_auth = h.value;
                }
            }

            var aw: std.Io.Writer.Allocating = .init(alloc);
            const reader = response.reader(&.{});
            _ = reader.streamRemaining(&aw.writer) catch {
                aw.deinit();
                return error.FetchFailed;
            };
            const resp_body = aw.toOwnedSlice() catch return error.FetchFailed;

            if (new_nonce) |n| store.updateSessionNonce(session.did, .pds, n);

            const is_nonce_err = new_nonce != null and (isDpopNonceError(response.head.status, resp_body) or isWwwAuthNonceError(response.head.status, www_auth));
            if (is_nonce_err) {
                alloc.free(resp_body);
                nonce = try alloc.dupe(u8, new_nonce.?);
                continue;
            }
            break .{ response.head.status, resp_body };
        } else {
            return error.DpopNonceRetryExhausted;
        };

        const status = inner[0];
        const resp_body = inner[1];

        if (status != .unauthorized) {
            return resp_body;
        }

        alloc.free(resp_body);
        if (attempt > 0 or refreshed) return error.Unauthorized;

        std.log.info("access token rejected for {s}, refreshing", .{session.did});
        const new_tokens = refreshAccessToken(alloc, session, &dpop_keypair) catch return error.Unauthorized;
        if (new_tokens.access_token.len > access_token_buf.len) return error.AuthHeaderTooLong;
        @memcpy(access_token_buf[0..new_tokens.access_token.len], new_tokens.access_token);
        access_token_len = new_tokens.access_token.len;
        refreshed = true;
    }

    return error.Unauthorized;
}

fn refreshAccessToken(
    alloc: Allocator,
    session: store.Session,
    dpop_keypair: *const zat.Keypair,
) !TokenResult {
    var authserver_meta = try fetchAuthServerMeta(alloc, session.authserver_iss);
    defer authserver_meta.deinit();

    const token_url = jsonGetString(authserver_meta.value, "token_endpoint") orelse return error.MissingTokenEndpoint;

    const client_keypair = getClientKeypair() catch return error.InvalidSessionKey;
    const client_id = cfg.client_id;

    const client_assertion = try zat_oauth.createClientAssertion(alloc, cfg.io, &client_keypair, client_id, session.authserver_iss);
    defer alloc.free(client_assertion);

    var authserver_nonce: ?[]const u8 = if (session.dpop_authserver_nonce.len > 0) session.dpop_authserver_nonce else null;

    for (0..2) |_| {
        const dpop_proof = try zat_oauth.createDpopProof(alloc, cfg.io, dpop_keypair, "POST", token_url, authserver_nonce, null);
        defer alloc.free(dpop_proof);

        const form_params = [_][2][]const u8{
            .{ "grant_type", "refresh_token" },
            .{ "refresh_token", session.refresh_token },
            .{ "client_id", client_id },
            .{ "client_assertion_type", "urn:ietf:params:oauth:client-assertion-type:jwt-bearer" },
            .{ "client_assertion", client_assertion },
        };
        const form_body = try zat_oauth.formEncode(alloc, &form_params);
        defer alloc.free(form_body);

        const result = try doPost(alloc, token_url, form_body, &.{
            .{ .name = "DPoP", .value = dpop_proof },
        });

        if (result.dpop_nonce) |n| store.updateSessionNonce(session.did, .authserver, n);

        if (isDpopNonceError(result.status, result.body)) {
            authserver_nonce = result.dpop_nonce;
            alloc.free(result.body);
            continue;
        }

        defer alloc.free(result.body);
        if (result.status != .ok) {
            std.log.warn("token refresh error ({t}): {s}", .{ result.status, result.body });
            return error.TokenRefreshFailed;
        }

        const parsed = try json.parseFromSlice(json.Value, alloc, result.body, .{});
        defer parsed.deinit();

        const new_access = try alloc.dupe(u8, jsonGetString(parsed.value, "access_token") orelse return error.MissingAccessToken);
        const new_refresh = try alloc.dupe(u8, jsonGetString(parsed.value, "refresh_token") orelse return error.MissingRefreshToken);

        store.updateSessionTokens(session.did, new_access, new_refresh);

        return .{
            .access_token = new_access,
            .refresh_token = new_refresh,
            .sub = try alloc.dupe(u8, session.did),
            .dpop_nonce = if (result.dpop_nonce) |n| try alloc.dupe(u8, n) else try alloc.dupe(u8, ""),
        };
    }
    return error.TokenRefreshFailed;
}

// ---------------------------------------------------------------------------
// HTTP route handlers — called from server.zig's dispatcher
// ---------------------------------------------------------------------------

pub fn handleClientMetadata(request: *http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const keypair = getClientKeypair() catch {
        try sendError(request, .internal_server_error, "server configuration error");
        return;
    };
    const jwk = keypair.jwk(alloc) catch {
        try sendError(request, .internal_server_error, "key error");
        return;
    };

    var body: std.ArrayList(u8) = .empty;
    try body.print(alloc,
        \\{{
        \\  "client_id": "{s}",
        \\  "client_name": "pub-search",
        \\  "client_uri": "{s}",
        \\  "application_type": "web",
        \\  "grant_types": ["authorization_code", "refresh_token"],
        \\  "response_types": ["code"],
        \\  "redirect_uris": ["{s}"],
        \\  "token_endpoint_auth_method": "private_key_jwt",
        \\  "token_endpoint_auth_signing_alg": "ES256",
        \\  "scope": "{s}",
        \\  "dpop_bound_access_tokens": true,
        \\  "jwks": {{"keys": [{s}]}}
        \\}}
    , .{ cfg.client_id, getClientOrigin(), cfg.redirect_uri, SCOPE, jwk });

    try sendJson(request, body.items);
}

pub fn handleJwks(request: *http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const keypair = getClientKeypair() catch {
        try sendError(request, .internal_server_error, "server configuration error");
        return;
    };
    const jwks = zat_oauth.jwksJson(alloc, &keypair) catch {
        try sendError(request, .internal_server_error, "key error");
        return;
    };
    try sendJson(request, jwks);
}

pub fn handleLogin(request: *http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const target = request.head.target;
    const handle_str = extractQueryParam(target, "handle") orelse {
        try sendError(request, .bad_request, "missing handle parameter");
        return;
    };

    var handle_resolver = zat.HandleResolver.init(cfg.io, alloc);
    defer handle_resolver.deinit();
    const did = handle_resolver.resolve(zat.Handle.parse(handle_str) orelse {
        try sendError(request, .bad_request, "invalid handle");
        return;
    }) catch {
        try sendError(request, .bad_request, "could not resolve handle");
        return;
    };

    var did_resolver = zat.DidResolver.init(cfg.io, alloc);
    defer did_resolver.deinit();
    var did_doc = did_resolver.resolve(zat.Did.parse(did) orelse {
        try sendError(request, .bad_request, "invalid DID");
        return;
    }) catch {
        try sendError(request, .bad_request, "could not resolve DID");
        return;
    };
    defer did_doc.deinit();

    const pds_url = did_doc.pdsEndpoint() orelse {
        try sendError(request, .bad_request, "no PDS endpoint");
        return;
    };

    const authserver_url = fetchAuthServerUrl(alloc, pds_url) catch {
        try sendError(request, .bad_request, "could not discover auth server");
        return;
    };

    var authserver_meta = fetchAuthServerMeta(alloc, authserver_url) catch {
        try sendError(request, .bad_request, "could not fetch auth server metadata");
        return;
    };
    defer authserver_meta.deinit();

    const authserver_iss = jsonGetString(authserver_meta.value, "issuer") orelse {
        try sendError(request, .bad_request, "auth server missing issuer");
        return;
    };
    const par_url = jsonGetString(authserver_meta.value, "pushed_authorization_request_endpoint") orelse {
        try sendError(request, .bad_request, "auth server missing PAR endpoint");
        return;
    };
    const authorization_endpoint = jsonGetString(authserver_meta.value, "authorization_endpoint") orelse {
        try sendError(request, .bad_request, "auth server missing authorization endpoint");
        return;
    };

    const pkce_verifier = try zat_oauth.generatePkceVerifier(alloc, cfg.io);
    const pkce_challenge = try zat_oauth.generatePkceChallenge(alloc, pkce_verifier);
    const state = try zat_oauth.generateState(alloc, cfg.io);

    var dpop_key_bytes: [32]u8 = undefined;
    cfg.io.random(&dpop_key_bytes);
    const dpop_keypair = zat.Keypair.fromSecretKey(.p256, dpop_key_bytes) catch {
        try sendError(request, .internal_server_error, "key generation failed");
        return;
    };

    const client_keypair = getClientKeypair() catch {
        try sendError(request, .internal_server_error, "server configuration error");
        return;
    };

    const par_result = sendParRequest(alloc, .{
        .par_url = par_url,
        .authserver_url = authserver_iss,
        .client_id = cfg.client_id,
        .redirect_uri = cfg.redirect_uri,
        .scope = SCOPE,
        .state = state,
        .pkce_challenge = pkce_challenge,
        .handle = handle_str,
        .client_keypair = &client_keypair,
        .dpop_keypair = &dpop_keypair,
    }) catch {
        try sendError(request, .bad_gateway, "PAR request failed");
        return;
    };

    const dpop_hex = std.fmt.bytesToHex(dpop_key_bytes, .lower);
    store.insertAuthRequest(
        state,
        authserver_iss,
        did,
        handle_str,
        pds_url,
        pkce_verifier,
        SCOPE,
        par_result.dpop_nonce,
        &dpop_hex,
    ) catch {
        try sendError(request, .internal_server_error, "could not store auth request");
        return;
    };

    var redirect_url: std.ArrayList(u8) = .empty;
    try redirect_url.print(alloc, "{s}?request_uri={s}&client_id={s}&state={s}", .{
        authorization_endpoint, par_result.request_uri, cfg.client_id, state,
    });
    try sendRedirect(request, redirect_url.items);
}

pub fn handleCallback(request: *http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const target = request.head.target;
    const code = extractQueryParam(target, "code") orelse {
        try sendError(request, .bad_request, "missing code");
        return;
    };
    const state = extractQueryParam(target, "state") orelse {
        try sendError(request, .bad_request, "missing state");
        return;
    };
    const iss_raw = extractQueryParam(target, "iss");
    const iss = if (iss_raw) |raw| blk: {
        const buf = try alloc.dupe(u8, raw);
        break :blk std.Uri.percentDecodeBackwards(buf, buf);
    } else null;

    const auth_req = (try store.getAuthRequest(alloc, state)) orelse {
        try sendError(request, .bad_request, "unknown state — login may have expired");
        return;
    };

    if (iss) |issuer| {
        if (!mem.eql(u8, issuer, auth_req.authserver_iss)) {
            try sendError(request, .bad_request, "issuer mismatch");
            return;
        }
    }

    const dpop_keypair = keypairFromHex(auth_req.dpop_private_key) catch {
        try sendError(request, .internal_server_error, "invalid stored key");
        return;
    };

    const client_keypair = getClientKeypair() catch {
        try sendError(request, .internal_server_error, "server configuration error");
        return;
    };

    var authserver_meta = fetchAuthServerMeta(alloc, auth_req.authserver_iss) catch {
        try sendError(request, .bad_gateway, "could not fetch auth server metadata");
        return;
    };
    defer authserver_meta.deinit();

    const token_url = jsonGetString(authserver_meta.value, "token_endpoint") orelse {
        try sendError(request, .bad_gateway, "auth server missing token endpoint");
        return;
    };

    const token_result = sendTokenRequest(alloc, .{
        .token_url = token_url,
        .authserver_url = auth_req.authserver_iss,
        .client_id = cfg.client_id,
        .redirect_uri = cfg.redirect_uri,
        .code = code,
        .pkce_verifier = auth_req.pkce_verifier,
        .client_keypair = &client_keypair,
        .dpop_keypair = &dpop_keypair,
        .dpop_nonce = auth_req.dpop_authserver_nonce,
    }) catch {
        try sendError(request, .bad_gateway, "token exchange failed");
        return;
    };

    if (!mem.eql(u8, token_result.sub, auth_req.did)) {
        try sendError(request, .bad_request, "token subject mismatch");
        return;
    }

    store.upsertSession(
        auth_req.did,
        auth_req.handle,
        auth_req.pds_url,
        auth_req.authserver_iss,
        token_result.access_token,
        token_result.refresh_token,
        token_result.dpop_nonce,
        "",
        auth_req.dpop_private_key,
    ) catch {
        try sendError(request, .internal_server_error, "could not store session");
        return;
    };
    store.deleteAuthRequest(state);

    // redirect back to the subscriptions page with ?logged_in={handle}
    var redirect_url: std.ArrayList(u8) = .empty;
    // use .html so the redirect lands on a file regardless of host server —
    // Cloudflare Pages serves /subscriptions and /subscriptions.html the same,
    // but plain static servers (like python -m http.server) only know the file.
    try redirect_url.print(alloc, "{s}/subscriptions.html?logged_in={s}", .{ cfg.frontend_origin, auth_req.handle });

    const session_token = store.createSessionToken(auth_req.did) catch {
        try sendError(request, .internal_server_error, "could not create session token");
        return;
    };

    // SameSite=None + Secure — the frontend is on a different origin than
    // the backend (pub-search.waow.tech vs leaflet-search-backend.fly.dev)
    // so we need cross-site cookies. Secure is required alongside None.
    var cookie_buf: [512]u8 = undefined;
    const cookie = std.fmt.bufPrint(
        &cookie_buf,
        "pubsearch_session={s}; HttpOnly; Secure; SameSite=None; Path=/; Max-Age=2592000",
        .{session_token},
    ) catch {
        try sendError(request, .internal_server_error, "cookie error");
        return;
    };

    try request.respond("", .{
        .status = .found,
        .extra_headers = &.{
            .{ .name = "location", .value = redirect_url.items },
            .{ .name = "set-cookie", .value = cookie },
        },
    });
}

pub fn handleLogout(request: *http.Server.Request) !void {
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "cookie")) {
            if (parseCookieValue(h.value, "pubsearch_session")) |token| {
                if (store.resolveSessionToken(token)) |did| {
                    store.deleteSession(did);
                }
                store.deleteSessionToken(token);
            }
            break;
        }
    }
    try request.respond("{\"ok\":true}", .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "set-cookie", .value = "pubsearch_session=; HttpOnly; Secure; SameSite=None; Path=/; Max-Age=0" },
        },
    });
}

// ---------------------------------------------------------------------------
// response helpers + cookie parsing
// ---------------------------------------------------------------------------

pub fn getSessionDid(request: *http.Server.Request) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "cookie")) {
            const token = parseCookieValue(h.value, "pubsearch_session") orelse continue;
            return store.resolveSessionToken(token);
        }
    }
    return null;
}

fn parseCookieValue(cookie_header: []const u8, name: []const u8) ?[]const u8 {
    var it = mem.splitSequence(u8, cookie_header, "; ");
    while (it.next()) |pair| {
        if (mem.startsWith(u8, pair, name)) {
            if (pair.len > name.len and pair[name.len] == '=') {
                return pair[name.len + 1 ..];
            }
        }
    }
    return null;
}

fn extractQueryParam(target: []const u8, name: []const u8) ?[]const u8 {
    const q_idx = mem.indexOf(u8, target, "?") orelse return null;
    const query = target[q_idx + 1 ..];
    var it = mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq_idx = mem.indexOf(u8, pair, "=") orelse continue;
        if (mem.eql(u8, pair[0..eq_idx], name)) {
            return pair[eq_idx + 1 ..];
        }
    }
    return null;
}

fn getClientOrigin() []const u8 {
    const cid = cfg.client_id;
    const scheme_end = mem.indexOf(u8, cid, "://") orelse return cid;
    const after = cid[scheme_end + 3 ..];
    const path_start = mem.indexOf(u8, after, "/") orelse return cid;
    return cid[0 .. scheme_end + 3 + path_start];
}

fn sendError(request: *http.Server.Request, status: http.Status, message: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{message}) catch "{\"error\":\"internal error\"}";
    try request.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = cfg.frontend_origin },
            .{ .name = "access-control-allow-credentials", .value = "true" },
            .{ .name = "vary", .value = "origin" },
        },
    });
}

fn sendJson(request: *http.Server.Request, body: []const u8) !void {
    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = cfg.frontend_origin },
            .{ .name = "access-control-allow-credentials", .value = "true" },
            .{ .name = "vary", .value = "origin" },
        },
    });
}

fn sendRedirect(request: *http.Server.Request, location: []const u8) !void {
    try request.respond("", .{
        .status = .found,
        .extra_headers = &.{
            .{ .name = "location", .value = location },
        },
    });
}

// ---------------------------------------------------------------------------
// high-level PDS write operations — used by notifications.zig to write
// subscription records to the user's PDS.
// ---------------------------------------------------------------------------

pub fn createRecord(
    alloc: Allocator,
    session: store.Session,
    collection: []const u8,
    record_json: []const u8,
) ![]u8 {
    const body = try std.fmt.allocPrint(
        alloc,
        "{{\"repo\":\"{s}\",\"collection\":\"{s}\",\"record\":{s}}}",
        .{ session.did, collection, record_json },
    );
    defer alloc.free(body);

    const resp = try pdsAuthedRequest(
        alloc,
        session,
        "POST",
        "/xrpc/com.atproto.repo.createRecord",
        body,
        "application/json",
        &.{},
    );
    defer alloc.free(resp);

    const parsed = json.parseFromSlice(json.Value, alloc, resp, .{}) catch |err| {
        const preview_len = @min(resp.len, 400);
        std.log.warn(
            "createRecord: response was not json ({t}). body[0..{d}]={s}",
            .{ err, preview_len, resp[0..preview_len] },
        );
        return error.ParseFailed;
    };
    defer parsed.deinit();

    const uri_v = parsed.value.object.get("uri") orelse return error.MissingUri;
    if (uri_v != .string) return error.MissingUri;
    return alloc.dupe(u8, uri_v.string);
}

pub fn deleteRecord(
    alloc: Allocator,
    session: store.Session,
    collection: []const u8,
    rkey: []const u8,
) !void {
    const body = try std.fmt.allocPrint(
        alloc,
        "{{\"repo\":\"{s}\",\"collection\":\"{s}\",\"rkey\":\"{s}\"}}",
        .{ session.did, collection, rkey },
    );
    defer alloc.free(body);

    const resp = try pdsAuthedRequest(
        alloc,
        session,
        "POST",
        "/xrpc/com.atproto.repo.deleteRecord",
        body,
        "application/json",
        &.{},
    );
    defer alloc.free(resp);
}

// ---------------------------------------------------------------------------
// chat.bsky sender — proxied through the user's PDS with atproto-proxy header
// so DMs are sent as the authenticated subscriber.
// ---------------------------------------------------------------------------

const BSKY_CHAT_PROXY = "did:web:api.bsky.chat#bsky_chat";

/// GET chat.bsky.convo.getConvoForMembers — returns a convoId suitable for
/// sendMessage. members is a slice of DIDs (1+, excluding the caller).
pub fn chatGetConvoForMembers(alloc: Allocator, session: store.Session, member_dids: []const []const u8) ![]const u8 {
    var path_buf: std.Io.Writer.Allocating = .init(alloc);
    try path_buf.writer.writeAll("/xrpc/chat.bsky.convo.getConvoForMembers");
    for (member_dids, 0..) |d, i| {
        const sep: u8 = if (i == 0) '?' else '&';
        try path_buf.writer.print("{c}members={s}", .{ sep, d });
    }
    const path = try path_buf.toOwnedSlice();
    defer alloc.free(path);

    const resp = try pdsAuthedRequest(
        alloc,
        session,
        "GET",
        path,
        null,
        "application/json",
        &.{.{ .name = "atproto-proxy", .value = BSKY_CHAT_PROXY }},
    );
    defer alloc.free(resp);

    const parsed = try json.parseFromSlice(json.Value, alloc, resp, .{});
    defer parsed.deinit();

    const convo = parsed.value.object.get("convo") orelse return error.MissingConvo;
    if (convo != .object) return error.MissingConvo;
    const id = convo.object.get("id") orelse return error.MissingConvoId;
    if (id != .string) return error.MissingConvoId;
    return alloc.dupe(u8, id.string);
}

/// POST chat.bsky.convo.sendMessage.
pub fn chatSendMessage(alloc: Allocator, session: store.Session, convo_id: []const u8, text: []const u8) !void {
    // JSON-escape the text into the body
    var body_buf: std.Io.Writer.Allocating = .init(alloc);
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
    defer alloc.free(body);

    const resp = try pdsAuthedRequest(
        alloc,
        session,
        "POST",
        "/xrpc/chat.bsky.convo.sendMessage",
        body,
        "application/json",
        &.{.{ .name = "atproto-proxy", .value = BSKY_CHAT_PROXY }},
    );
    defer alloc.free(resp);
}
