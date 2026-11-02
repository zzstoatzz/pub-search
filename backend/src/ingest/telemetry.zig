const std = @import("std");
const logfire = @import("logfire");

pub const DropReason = enum {
    author_only,
    banned_did,
    bridged_repo,
    content_hash_dupe,
    extraction_error,
    invalid_did,
    missing_title,
    no_content,
    no_inner_record,
    pckt_pub_missing_ref,
    pub_missing_name,
    recommend_missing_document,
    republish_stale,
    subscription_missing_publication,
    test_domain,
    uri_too_long,
};

var drops: [@typeInfo(DropReason).@"enum".field_names.len]std.atomic.Value(u64) = @splat(.init(0));

pub fn recordDrop(reason: DropReason) void {
    _ = drops[@backingInt(reason)].fetchAdd(1, .monotonic);
}

pub const Heartbeat = struct {
    last_emitted_ns: ?i96 = null,

    pub fn shouldEmit(self: *Heartbeat, now_ns: i96) bool {
        if (self.last_emitted_ns) |last| {
            if (now_ns - last < 60 * std.time.ns_per_s) return false;
        }
        self.last_emitted_ns = now_ns;
        return true;
    }
};

pub fn emitHeartbeat(received: usize, durable_seq: u64) void {
    const span = logfire.span("ingest.heartbeat", .{
        .received = received,
        .durable_seq = durable_seq,
    });
    defer span.end();
    inline for (@typeInfo(DropReason).@"enum".field_names, 0..) |name, i| {
        span.setAttribute("dropped." ++ name, drops[i].load(.monotonic));
    }
}

test "a burst of dropped records does not increase heartbeat volume" {
    var heartbeat: Heartbeat = .{};
    var emitted: usize = 0;
    const before = drops[@backingInt(DropReason.banned_did)].load(.monotonic);
    for (0..100_000) |i| {
        recordDrop(.banned_did);
        const elapsed_ns: i96 = @as(i96, @intCast(i)) * 6 * std.time.ns_per_ms;
        if (heartbeat.shouldEmit(elapsed_ns)) emitted += 1;
    }
    try std.testing.expectEqual(@as(usize, 10), emitted);
    try std.testing.expectEqual(before + 100_000, drops[@backingInt(DropReason.banned_did)].load(.monotonic));
}

test "quiet traffic still emits the liveness heartbeat" {
    var heartbeat: Heartbeat = .{};
    var emitted: usize = 0;
    for (0..30) |minute| {
        if (heartbeat.shouldEmit(@as(i96, @intCast(minute)) * 60 * std.time.ns_per_s)) emitted += 1;
    }
    try std.testing.expectEqual(@as(usize, 30), emitted);
}
