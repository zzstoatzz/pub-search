//! in-memory oauth session store.
//!
//! lifted from ken/backend/src/state.zig. OAuth sessions live only in memory;
//! on backend restart users re-auth. acceptable UX because subscriptions
//! themselves live on the user's PDS (source of truth) + a local mirror
//! keyed by DID, which survives restarts. the session is just the bearer
//! for creating/deleting records.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

var gpa: Allocator = undefined;
var io: Io = undefined;
pub var mutex: Io.Mutex = .init;

const StoredAuthRequest = struct {
    state: []u8,
    authserver_iss: []u8,
    did: []u8,
    handle: []u8,
    pds_url: []u8,
    pkce_verifier: []u8,
    scope: []u8,
    dpop_authserver_nonce: []u8,
    dpop_private_key: []u8,
    created_at: i64,

    fn deinit(self: *StoredAuthRequest, a: Allocator) void {
        a.free(self.state);
        a.free(self.authserver_iss);
        a.free(self.did);
        a.free(self.handle);
        a.free(self.pds_url);
        a.free(self.pkce_verifier);
        a.free(self.scope);
        a.free(self.dpop_authserver_nonce);
        a.free(self.dpop_private_key);
    }
};

const StoredSession = struct {
    did: []u8,
    handle: []u8,
    pds_url: []u8,
    authserver_iss: []u8,
    access_token: []u8,
    refresh_token: []u8,
    dpop_authserver_nonce: []u8,
    dpop_pds_nonce: []u8,
    dpop_private_key: []u8,
    created_at: i64,

    fn deinit(self: *StoredSession, a: Allocator) void {
        a.free(self.did);
        a.free(self.handle);
        a.free(self.pds_url);
        a.free(self.authserver_iss);
        a.free(self.access_token);
        a.free(self.refresh_token);
        a.free(self.dpop_authserver_nonce);
        a.free(self.dpop_pds_nonce);
        a.free(self.dpop_private_key);
    }
};

var auth_requests: std.StringHashMap(StoredAuthRequest) = undefined;
var sessions: std.StringHashMap(StoredSession) = undefined;
/// opaque session cookie token (hex-encoded 32 random bytes) → DID. the
/// cookie never contains the DID itself — DIDs are public identifiers.
var session_tokens: std.StringHashMap([]u8) = undefined;

fn timestamp() i64 {
    return @intCast(@divFloor(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
}

pub fn init(app_io: Io, app_allocator: Allocator) void {
    io = app_io;
    gpa = app_allocator;
    auth_requests = std.StringHashMap(StoredAuthRequest).init(gpa);
    sessions = std.StringHashMap(StoredSession).init(gpa);
    session_tokens = std.StringHashMap([]u8).init(gpa);
    std.log.info("state: in-memory (oauth sessions reset on restart)", .{});
}

pub fn close() void {}

pub const AuthRequest = struct {
    state: []const u8,
    authserver_iss: []const u8,
    did: []const u8,
    handle: []const u8,
    pds_url: []const u8,
    pkce_verifier: []const u8,
    scope: []const u8,
    dpop_authserver_nonce: []const u8,
    dpop_private_key: []const u8,
};

pub const Session = struct {
    did: []const u8,
    handle: []const u8,
    pds_url: []const u8,
    authserver_iss: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
    dpop_authserver_nonce: []const u8,
    dpop_pds_nonce: []const u8,
    dpop_private_key: []const u8,
};

pub fn insertAuthRequest(
    state: []const u8,
    authserver_iss: []const u8,
    did: []const u8,
    handle: []const u8,
    pds_url: []const u8,
    pkce_verifier: []const u8,
    scope: []const u8,
    dpop_nonce: []const u8,
    dpop_private_key_hex: []const u8,
) !void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    const stored: StoredAuthRequest = .{
        .state = try gpa.dupe(u8, state),
        .authserver_iss = try gpa.dupe(u8, authserver_iss),
        .did = try gpa.dupe(u8, did),
        .handle = try gpa.dupe(u8, handle),
        .pds_url = try gpa.dupe(u8, pds_url),
        .pkce_verifier = try gpa.dupe(u8, pkce_verifier),
        .scope = try gpa.dupe(u8, scope),
        .dpop_authserver_nonce = try gpa.dupe(u8, dpop_nonce),
        .dpop_private_key = try gpa.dupe(u8, dpop_private_key_hex),
        .created_at = timestamp(),
    };
    if (auth_requests.fetchRemove(stored.state)) |kv| {
        var prev = kv.value;
        prev.deinit(gpa);
    }
    try auth_requests.put(stored.state, stored);
}

pub fn getAuthRequest(arena: Allocator, state: []const u8) !?AuthRequest {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    const stored = auth_requests.getPtr(state) orelse return null;
    return AuthRequest{
        .state = try arena.dupe(u8, stored.state),
        .authserver_iss = try arena.dupe(u8, stored.authserver_iss),
        .did = try arena.dupe(u8, stored.did),
        .handle = try arena.dupe(u8, stored.handle),
        .pds_url = try arena.dupe(u8, stored.pds_url),
        .pkce_verifier = try arena.dupe(u8, stored.pkce_verifier),
        .scope = try arena.dupe(u8, stored.scope),
        .dpop_authserver_nonce = try arena.dupe(u8, stored.dpop_authserver_nonce),
        .dpop_private_key = try arena.dupe(u8, stored.dpop_private_key),
    };
}

pub fn deleteAuthRequest(state: []const u8) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (auth_requests.fetchRemove(state)) |kv| {
        var stored = kv.value;
        stored.deinit(gpa);
    }
}

pub fn upsertSession(
    did: []const u8,
    handle: []const u8,
    pds_url: []const u8,
    authserver_iss: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
    dpop_authserver_nonce: []const u8,
    dpop_pds_nonce: []const u8,
    dpop_private_key_hex: []const u8,
) !void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    const new_session: StoredSession = .{
        .did = try gpa.dupe(u8, did),
        .handle = try gpa.dupe(u8, handle),
        .pds_url = try gpa.dupe(u8, pds_url),
        .authserver_iss = try gpa.dupe(u8, authserver_iss),
        .access_token = try gpa.dupe(u8, access_token),
        .refresh_token = try gpa.dupe(u8, refresh_token),
        .dpop_authserver_nonce = try gpa.dupe(u8, dpop_authserver_nonce),
        .dpop_pds_nonce = try gpa.dupe(u8, dpop_pds_nonce),
        .dpop_private_key = try gpa.dupe(u8, dpop_private_key_hex),
        .created_at = timestamp(),
    };

    if (sessions.fetchRemove(new_session.did)) |kv| {
        var prev = kv.value;
        prev.deinit(gpa);
    }
    try sessions.put(new_session.did, new_session);
}

pub fn getSession(arena: Allocator, did: []const u8) !?Session {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    const stored = sessions.getPtr(did) orelse return null;
    return Session{
        .did = try arena.dupe(u8, stored.did),
        .handle = try arena.dupe(u8, stored.handle),
        .pds_url = try arena.dupe(u8, stored.pds_url),
        .authserver_iss = try arena.dupe(u8, stored.authserver_iss),
        .access_token = try arena.dupe(u8, stored.access_token),
        .refresh_token = try arena.dupe(u8, stored.refresh_token),
        .dpop_authserver_nonce = try arena.dupe(u8, stored.dpop_authserver_nonce),
        .dpop_pds_nonce = try arena.dupe(u8, stored.dpop_pds_nonce),
        .dpop_private_key = try arena.dupe(u8, stored.dpop_private_key),
    };
}

pub fn deleteSession(did: []const u8) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (sessions.fetchRemove(did)) |kv| {
        var stored = kv.value;
        stored.deinit(gpa);
    }
}

pub fn updateSessionNonce(did: []const u8, field: enum { authserver, pds }, nonce: []const u8) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const stored = sessions.getPtr(did) orelse return;
    const new_val = gpa.dupe(u8, nonce) catch return;
    switch (field) {
        .authserver => {
            gpa.free(stored.dpop_authserver_nonce);
            stored.dpop_authserver_nonce = new_val;
        },
        .pds => {
            gpa.free(stored.dpop_pds_nonce);
            stored.dpop_pds_nonce = new_val;
        },
    }
}

pub fn updateSessionTokens(did: []const u8, access_token: []const u8, refresh_token: []const u8) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const stored = sessions.getPtr(did) orelse return;
    const new_at = gpa.dupe(u8, access_token) catch return;
    const new_rt = gpa.dupe(u8, refresh_token) catch {
        gpa.free(new_at);
        return;
    };
    gpa.free(stored.access_token);
    gpa.free(stored.refresh_token);
    stored.access_token = new_at;
    stored.refresh_token = new_rt;
}

pub fn createSessionToken(did: []const u8) ![]const u8 {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    var rand_bytes: [32]u8 = undefined;
    io.random(&rand_bytes);

    const token = std.fmt.bytesToHex(rand_bytes, .lower);

    const key = try gpa.dupe(u8, &token);
    const val = try gpa.dupe(u8, did);
    try session_tokens.put(key, val);
    return key;
}

pub fn resolveSessionToken(token: []const u8) ?[]const u8 {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return session_tokens.get(token);
}

pub fn deleteSessionToken(token: []const u8) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (session_tokens.fetchRemove(token)) |kv| {
        gpa.free(kv.key);
        gpa.free(kv.value);
    }
}
