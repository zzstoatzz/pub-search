//! Subscription storage + match + bsky DM delivery.
//!
//! Subscriptions live as `tech.waow.pub-search.subscription` records on each
//! user's PDS (portable, inspectable, publicly listable). We keep a local
//! SQLite mirror so match at ingest time is O(log n).
//!
//! Delivery: chat.bsky DMs. The subscription *owner* (the person who made
//! the subscription) is who the DM is sent *from* — so we pull their oauth
//! session on each delivery and call chat.bsky.convo.getConvoForMembers
//! + sendMessage via their PDS (proxied to did:web:api.bsky.chat).
//!
//! Session liveness: sessions are in-memory. If the subscriber hasn't
//! logged in since the last backend restart, deliveries for their subs
//! are skipped until they next sign in. This is a known limitation of
//! the ken-style memory store we're reusing. Persistent session storage
//! is a separate upgrade.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const json = std.json;
const Allocator = std.mem.Allocator;
const logfire = @import("logfire");
const db = @import("db.zig");
const bsky_bot = @import("bsky_bot.zig");

pub const SUBSCRIPTION_COLLECTION = "tech.waow.pub-search.subscription";

var global_io: ?Io = null;
var global_alloc: ?Allocator = null;

const QUEUE_CAPACITY = 1024;

const DeliveryJob = struct {
    /// the subscriber — who receives the DM from the bot
    owner_did: []u8,
    sub_rkey: []u8,
    trigger_kind: []u8,
    trigger_value: []u8,
    doc_title: []u8,
    doc_url: []u8, // resolved frontend url if possible, else at-uri

    fn deinit(self: *DeliveryJob, a: Allocator) void {
        a.free(self.owner_did);
        a.free(self.sub_rkey);
        a.free(self.trigger_kind);
        a.free(self.trigger_value);
        a.free(self.doc_title);
        a.free(self.doc_url);
    }
};

var queue: std.ArrayListUnmanaged(DeliveryJob) = .empty;
var queue_mutex: Io.Mutex = .init;
var queue_cond: Io.Condition = .init;
var dropped_count = std.atomic.Value(u64).init(0);
var delivered_count = std.atomic.Value(u64).init(0);
var failed_count = std.atomic.Value(u64).init(0);

// ---------------------------------------------------------------------------
// init + schema
// ---------------------------------------------------------------------------

pub fn init(allocator: Allocator, io: Io) void {
    global_io = io;
    global_alloc = allocator;
}

pub fn initSchema() !void {
    const local = db.getLocalDbRaw() orelse {
        std.log.warn("notifications: local db not available, skipping schema init", .{});
        return;
    };

    local.lock();
    defer local.unlock();
    const c = local.getConn() orelse return error.NotOpen;

    c.exec(
        \\CREATE TABLE IF NOT EXISTS subscriptions (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  owner_did TEXT NOT NULL,
        \\  rkey TEXT NOT NULL,
        \\  trigger_kind TEXT NOT NULL,
        \\  trigger_value TEXT NOT NULL,
        \\  destination_kind TEXT NOT NULL,
        \\  destination_value TEXT NOT NULL,
        \\  secret TEXT DEFAULT '',
        \\  label TEXT DEFAULT '',
        \\  created_at TEXT NOT NULL,
        \\  UNIQUE(owner_did, rkey)
        \\)
    , .{}) catch |err| {
        std.log.err("notifications: failed to create subscriptions table: {}", .{err});
        return err;
    };

    c.exec("CREATE INDEX IF NOT EXISTS idx_sub_match ON subscriptions(trigger_kind, trigger_value)", .{}) catch {};
    c.exec("CREATE INDEX IF NOT EXISTS idx_sub_owner ON subscriptions(owner_did)", .{}) catch {};

    // migrations — idempotent adds for columns we introduced after initial ship
    c.exec("ALTER TABLE subscriptions ADD COLUMN last_error TEXT DEFAULT ''", .{}) catch {};
    c.exec("ALTER TABLE subscriptions ADD COLUMN last_error_at TEXT DEFAULT ''", .{}) catch {};

    std.log.info("notifications: schema ready", .{});
}

// ---------------------------------------------------------------------------
// CRUD on the local mirror
// ---------------------------------------------------------------------------

pub const NewSubscription = struct {
    owner_did: []const u8,
    rkey: []const u8,
    trigger_kind: []const u8,
    trigger_value: []const u8,
    destination_kind: []const u8,
    destination_value: []const u8,
    secret: []const u8,
    label: []const u8,
    created_at: []const u8,
};

pub fn insert(s: NewSubscription) !void {
    const local = db.getLocalDbRaw() orelse return error.LocalDbUnavailable;
    try local.exec(
        \\INSERT OR REPLACE INTO subscriptions
        \\  (owner_did, rkey, trigger_kind, trigger_value, destination_kind, destination_value, secret, label, created_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    , .{
        s.owner_did,
        s.rkey,
        s.trigger_kind,
        s.trigger_value,
        s.destination_kind,
        s.destination_value,
        s.secret,
        s.label,
        s.created_at,
    });
}

pub fn deleteByRkey(owner_did: []const u8, rkey: []const u8) !void {
    const local = db.getLocalDbRaw() orelse return error.LocalDbUnavailable;
    try local.exec("DELETE FROM subscriptions WHERE owner_did = ? AND rkey = ?", .{ owner_did, rkey });
}

pub fn listByOwnerJson(arena: Allocator, owner_did: []const u8) ![]const u8 {
    const local = db.getLocalDbRaw() orelse return error.LocalDbUnavailable;

    var rows = try local.query(
        \\SELECT rkey, trigger_kind, trigger_value, destination_kind, destination_value, label, created_at,
        \\       COALESCE(last_error, ''), COALESCE(last_error_at, '')
        \\FROM subscriptions WHERE owner_did = ? ORDER BY created_at DESC
    , .{owner_did});
    defer rows.deinit();

    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    var jw: json.Stringify = .{ .writer = &out.writer };

    try jw.beginArray();
    while (rows.next()) |row| {
        try jw.beginObject();
        try jw.objectField("rkey");
        try jw.write(row.text(0));
        try jw.objectField("triggerKind");
        try jw.write(row.text(1));
        try jw.objectField("triggerValue");
        try jw.write(row.text(2));
        try jw.objectField("destinationKind");
        try jw.write(row.text(3));
        try jw.objectField("destinationValue");
        try jw.write(row.text(4));
        try jw.objectField("label");
        try jw.write(row.text(5));
        try jw.objectField("createdAt");
        try jw.write(row.text(6));
        try jw.objectField("lastError");
        try jw.write(row.text(7));
        try jw.objectField("lastErrorAt");
        try jw.write(row.text(8));
        try jw.endObject();
    }
    try jw.endArray();

    return try out.toOwnedSlice();
}

/// Mark a delivery attempt's outcome on the subscription row. Empty err
/// string = success (clears any prior error).
pub fn recordDeliveryOutcome(owner_did: []const u8, rkey: []const u8, err: []const u8) void {
    const local = db.getLocalDbRaw() orelse return;
    if (err.len > 0) {
        const trimmed = err[0..@min(err.len, 500)];
        local.exec(
            "UPDATE subscriptions SET last_error = ?, last_error_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE owner_did = ? AND rkey = ?",
            .{ trimmed, owner_did, rkey },
        ) catch |e| logfire.warn("recordDeliveryOutcome: {}", .{e});
    } else {
        local.exec(
            "UPDATE subscriptions SET last_error = '', last_error_at = '' WHERE owner_did = ? AND rkey = ?",
            .{ owner_did, rkey },
        ) catch |e| logfire.warn("recordDeliveryOutcome(clear): {}", .{e});
    }
}

// ---------------------------------------------------------------------------
// match + enqueue
// ---------------------------------------------------------------------------

pub const DocIndexed = struct {
    uri: []const u8,
    did: []const u8,
    title: []const u8,
    platform: []const u8,
    publication_uri: []const u8,
    base_path: []const u8,
    path: []const u8,
    created_at: []const u8,
    tags: []const []const u8,
};

pub fn onDocumentIndexed(doc: DocIndexed) void {
    const alloc = global_alloc orelse return;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const doc_url = buildDocUrl(a, doc) catch return;

    matchAndEnqueue(a, "author", doc.did, doc.title, doc_url);
    if (doc.publication_uri.len > 0) {
        matchAndEnqueue(a, "publication", doc.publication_uri, doc.title, doc_url);
    }
    matchAndEnqueue(a, "platform", doc.platform, doc.title, doc_url);
    for (doc.tags) |tag| {
        matchAndEnqueue(a, "tag", tag, doc.title, doc_url);
    }
}

fn buildDocUrl(arena: Allocator, doc: DocIndexed) ![]const u8 {
    // pub-search frontend routes map (did, platform, path) → public URL.
    // if base_path + path are present we can reconstruct the canonical
    // frontend link; otherwise fall back to the at-uri.
    if (doc.base_path.len > 0 and doc.path.len > 0) {
        return try std.fmt.allocPrint(arena, "https://{s}{s}", .{ doc.base_path, doc.path });
    }
    if (doc.base_path.len > 0) {
        return try std.fmt.allocPrint(arena, "https://{s}", .{doc.base_path});
    }
    return try arena.dupe(u8, doc.uri);
}

fn matchAndEnqueue(arena: Allocator, kind: []const u8, value: []const u8, doc_title: []const u8, doc_url: []const u8) void {
    const local = db.getLocalDbRaw() orelse return;

    var rows = local.query(
        \\SELECT rkey, owner_did, trigger_kind, trigger_value
        \\FROM subscriptions
        \\WHERE trigger_kind = ? AND trigger_value = ?
    , .{ kind, value }) catch |err| {
        std.log.warn("notifications: match query failed ({s}={s}): {}", .{ kind, value, err });
        return;
    };
    defer rows.deinit();

    while (rows.next()) |row| {
        const rkey = row.text(0);
        const owner_did = row.text(1);
        const trigger_kind = row.text(2);
        const trigger_value = row.text(3);

        enqueue(.{
            .owner_did = owner_did,
            .sub_rkey = rkey,
            .trigger_kind = trigger_kind,
            .trigger_value = trigger_value,
            .doc_title = doc_title,
            .doc_url = doc_url,
        }, arena) catch |err| {
            std.log.warn("notifications: enqueue failed: {}", .{err});
            _ = dropped_count.fetchAdd(1, .monotonic);
        };
    }
}

// ---------------------------------------------------------------------------
// test fire — build a synthetic delivery for a single sub
// ---------------------------------------------------------------------------

pub fn testFire(arena: Allocator, owner_did: []const u8, rkey: []const u8) !void {
    const local = db.getLocalDbRaw() orelse return error.LocalDbUnavailable;

    var rows = try local.query(
        \\SELECT trigger_kind, trigger_value
        \\FROM subscriptions WHERE owner_did = ? AND rkey = ?
    , .{ owner_did, rkey });
    defer rows.deinit();

    const row = rows.next() orelse {
        logfire.warn("testFire: sub not found owner={s} rkey={s}", .{ owner_did, rkey });
        return error.NotFound;
    };
    const trigger_kind = row.text(0);
    const trigger_value = row.text(1);

    logfire.info("testFire: enqueuing sub rkey={s} owner={s}", .{ rkey, owner_did });

    try enqueue(.{
        .owner_did = owner_did,
        .sub_rkey = rkey,
        .trigger_kind = trigger_kind,
        .trigger_value = trigger_value,
        .doc_title = "[test delivery] pub-search subscription fire",
        .doc_url = "https://pub-search.waow.tech/subscriptions",
    }, arena);
}

// ---------------------------------------------------------------------------
// queue
// ---------------------------------------------------------------------------

const EnqueueInput = struct {
    owner_did: []const u8,
    sub_rkey: []const u8,
    trigger_kind: []const u8,
    trigger_value: []const u8,
    doc_title: []const u8,
    doc_url: []const u8,
};

fn enqueue(in: EnqueueInput, _: Allocator) !void {
    const alloc = global_alloc orelse return error.NotInitialized;
    const io = global_io orelse return error.NotInitialized;

    queue_mutex.lockUncancelable(io);
    defer queue_mutex.unlock(io);

    if (queue.items.len >= QUEUE_CAPACITY) return error.QueueFull;

    const job: DeliveryJob = .{
        .owner_did = try alloc.dupe(u8, in.owner_did),
        .sub_rkey = try alloc.dupe(u8, in.sub_rkey),
        .trigger_kind = try alloc.dupe(u8, in.trigger_kind),
        .trigger_value = try alloc.dupe(u8, in.trigger_value),
        .doc_title = try alloc.dupe(u8, in.doc_title),
        .doc_url = try alloc.dupe(u8, in.doc_url),
    };
    try queue.append(alloc, job);
    queue_cond.signal(io);
}

fn dequeueBlocking(io: Io) ?DeliveryJob {
    queue_mutex.lockUncancelable(io);
    defer queue_mutex.unlock(io);
    while (queue.items.len == 0) {
        queue_cond.wait(io, &queue_mutex) catch return null;
    }
    return queue.orderedRemove(0);
}

// ---------------------------------------------------------------------------
// worker
// ---------------------------------------------------------------------------

pub fn startWorker() !void {
    const io = global_io orelse return error.NotInitialized;
    const t = try std.Thread.spawn(.{}, workerLoop, .{io});
    t.detach();
    std.log.info("notifications: bsky DM worker started", .{});
}

fn workerLoop(io: Io) void {
    const alloc = global_alloc orelse return;
    while (true) {
        var job = dequeueBlocking(io) orelse continue;
        defer job.deinit(alloc);

        if (deliver(alloc, &job)) |_| {
            recordDeliveryOutcome(job.owner_did, job.sub_rkey, "");
        } else |err| {
            _ = failed_count.fetchAdd(1, .monotonic);
            var buf: [256]u8 = undefined;
            const err_name = @errorName(err);
            const last = bsky_bot.lastErrorSnippet();
            const summary = if (last.len > 0)
                std.fmt.bufPrint(&buf, "{s}: {s}", .{ err_name, last }) catch err_name
            else
                err_name;
            logfire.warn("notifications: delivery failed sub={s}: {s}", .{ job.sub_rkey, summary });
            recordDeliveryOutcome(job.owner_did, job.sub_rkey, summary);
        }
    }
}

fn deliver(alloc: Allocator, job: *const DeliveryJob) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    logfire.info("deliver: starting sub={s} to_did={s}", .{ job.sub_rkey, job.owner_did });

    const text = try std.fmt.allocPrint(a,
        \\new on pub-search — matched your {s}="{s}" subscription
        \\
        \\{s}
        \\{s}
    , .{ job.trigger_kind, job.trigger_value, job.doc_title, job.doc_url });

    try bsky_bot.sendDm(a, job.owner_did, text);

    logfire.info("deliver: DM sent sub={s}", .{job.sub_rkey});
    _ = delivered_count.fetchAdd(1, .monotonic);
}

pub fn stats() struct { delivered: u64, failed: u64, dropped: u64, queued: usize } {
    const io = global_io orelse return .{ .delivered = 0, .failed = 0, .dropped = 0, .queued = 0 };
    queue_mutex.lockUncancelable(io);
    defer queue_mutex.unlock(io);
    return .{
        .delivered = delivered_count.load(.monotonic),
        .failed = failed_count.load(.monotonic),
        .dropped = dropped_count.load(.monotonic),
        .queued = queue.items.len,
    };
}
