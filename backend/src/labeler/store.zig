//! SQLite-backed label store (zqlite).
//!
//! Same public API as labelz's store (init/insert/queryByCursor/
//! queryBySubject/latestSeq + StoredLabel), so server.zig is lifted verbatim —
//! but backed by the backend's vendored zqlite instead of a raw sqlite3 cImport
//! (the backend already links sqlite through zqlite; a second sqlite would
//! conflict). Labels live in their OWN db file, not the frozen replica: the
//! replica is wiped+replaced by snapshot adoption, and labels must survive that.
//!
//! The ws server handles queries on per-connection threads while emit() writes
//! from elsewhere; safe because zqlite's sqlite is built in serialized threading
//! mode (the default — same reason the backend's read pool shares the lib across
//! threads). Every call prepares + finalizes its own statement.

const std = @import("std");
const zqlite = @import("zqlite");
const label_mod = @import("label.zig");
const Label = label_mod.Label;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.labeler_store);

pub const StoredLabel = struct {
    seq: i64,
    label: Label,
    /// pre-encoded signed CBOR (stored as blob, avoids re-encoding)
    encoded: []const u8,
};

pub const Store = struct {
    conn: zqlite.Conn,

    pub fn init(path: [*:0]const u8) !Store {
        const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite;
        const conn = try zqlite.open(path, flags);
        errdefer conn.close();

        conn.execNoArgs("PRAGMA journal_mode=WAL") catch {};
        conn.execNoArgs("PRAGMA busy_timeout=5000") catch {};

        try conn.execNoArgs(
            \\CREATE TABLE IF NOT EXISTS labels (
            \\  seq INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  src TEXT NOT NULL,
            \\  uri TEXT NOT NULL,
            \\  cid TEXT,
            \\  val TEXT NOT NULL,
            \\  neg INTEGER NOT NULL DEFAULT 0,
            \\  cts TEXT NOT NULL,
            \\  exp TEXT,
            \\  sig BLOB NOT NULL,
            \\  encoded BLOB NOT NULL
            \\)
        );
        try conn.execNoArgs("CREATE INDEX IF NOT EXISTS idx_labels_uri ON labels(uri)");

        return .{ .conn = conn };
    }

    pub fn deinit(self: *Store) void {
        self.conn.close();
    }

    /// insert a signed label, returns the assigned sequence number.
    pub fn insert(self: *Store, lbl: *const Label, encoded: []const u8) !i64 {
        if (lbl.sig == null) return error.UnsignedLabel;

        try self.conn.exec(
            \\INSERT INTO labels (src, uri, cid, val, neg, cts, exp, sig, encoded)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        , .{
            lbl.src,
            lbl.uri,
            lbl.cid,
            lbl.val,
            lbl.neg,
            lbl.cts,
            lbl.exp,
            zqlite.blob(lbl.sig.?),
            zqlite.blob(encoded),
        });
        return self.conn.lastInsertedRowId();
    }

    /// get labels after a cursor (sequence number), up to limit.
    pub fn queryByCursor(self: *Store, allocator: Allocator, cursor: i64, limit: i64) ![]StoredLabel {
        var r = try self.conn.rows(
            "SELECT seq, src, uri, cid, val, neg, cts, exp, sig, encoded FROM labels WHERE seq > ? ORDER BY seq ASC LIMIT ?",
            .{ cursor, limit },
        );
        defer r.deinit();
        return collect(allocator, &r);
    }

    /// get labels for a specific subject URI.
    pub fn queryBySubject(self: *Store, allocator: Allocator, uri: []const u8) ![]StoredLabel {
        var r = try self.conn.rows(
            "SELECT seq, src, uri, cid, val, neg, cts, exp, sig, encoded FROM labels WHERE uri = ? ORDER BY seq ASC",
            .{uri},
        );
        defer r.deinit();
        return collect(allocator, &r);
    }

    /// get the latest sequence number (0 if empty).
    pub fn latestSeq(self: *Store) i64 {
        const row = self.conn.row("SELECT COALESCE(MAX(seq), 0) FROM labels", .{}) catch return 0;
        if (row) |rw| {
            defer rw.deinit();
            return rw.int(0);
        }
        return 0;
    }

    /// collect rows into owned StoredLabels. Each field is duped into
    /// `allocator`; the caller frees them (same contract server.zig expects).
    fn collect(allocator: Allocator, r: *zqlite.Rows) ![]StoredLabel {
        var results: std.ArrayList(StoredLabel) = .empty;
        errdefer {
            for (results.items) |item| freeStored(allocator, item);
            results.deinit(allocator);
        }
        while (r.next()) |row| {
            const encoded = try allocator.dupe(u8, row.blob(9));
            errdefer allocator.free(encoded);
            const sig = try allocator.dupe(u8, row.blob(8));
            errdefer allocator.free(sig);
            try results.append(allocator, .{
                .seq = row.int(0),
                .label = .{
                    .src = try allocator.dupe(u8, row.text(1)),
                    .uri = try allocator.dupe(u8, row.text(2)),
                    .cid = try dupeOpt(allocator, row.nullableText(3)),
                    .val = try allocator.dupe(u8, row.text(4)),
                    .neg = row.boolean(5),
                    .cts = try allocator.dupe(u8, row.text(6)),
                    .exp = try dupeOpt(allocator, row.nullableText(7)),
                    .sig = sig,
                },
                .encoded = encoded,
            });
        }
        return results.toOwnedSlice(allocator);
    }
};

fn dupeOpt(allocator: Allocator, v: ?[]const u8) !?[]const u8 {
    return if (v) |s| try allocator.dupe(u8, s) else null;
}

/// free a StoredLabel's owned fields (mirrors what server.zig frees).
pub fn freeStored(allocator: Allocator, item: StoredLabel) void {
    allocator.free(item.label.src);
    allocator.free(item.label.uri);
    allocator.free(item.label.val);
    allocator.free(item.label.cts);
    allocator.free(item.encoded);
    if (item.label.sig) |s| allocator.free(s);
    if (item.label.cid) |ci| allocator.free(ci);
    if (item.label.exp) |e| allocator.free(e);
}

// === tests ===

test "store insert and query by cursor" {
    var store = try Store.init(":memory:");
    defer store.deinit();
    const allocator = std.testing.allocator;

    var label1 = Label{
        .src = "did:plc:labeler",
        .uri = "did:plc:user1",
        .val = "bulk-mirror",
        .cts = "2024-01-01T00:00:00.000Z",
        .sig = &(.{0xaa} ** 64),
    };
    const seq1 = try store.insert(&label1, "encoded1");

    var label2 = Label{
        .src = "did:plc:labeler",
        .uri = "did:plc:user2",
        .val = "bulk-mirror",
        .cts = "2024-01-01T00:01:00.000Z",
        .sig = &(.{0xbb} ** 64),
    };
    const seq2 = try store.insert(&label2, "encoded2");

    try std.testing.expect(seq2 > seq1);
    try std.testing.expectEqual(seq2, store.latestSeq());

    const all = try store.queryByCursor(allocator, 0, 100);
    defer {
        for (all) |item| freeStored(allocator, item);
        allocator.free(all);
    }
    try std.testing.expectEqual(@as(usize, 2), all.len);

    const after = try store.queryByCursor(allocator, seq1, 100);
    defer {
        for (after) |item| freeStored(allocator, item);
        allocator.free(after);
    }
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqualStrings("did:plc:user2", after[0].label.uri);
}

test "store query by subject" {
    var store = try Store.init(":memory:");
    defer store.deinit();
    const allocator = std.testing.allocator;

    var label1 = Label{
        .src = "did:plc:labeler",
        .uri = "did:plc:target",
        .val = "bulk-mirror",
        .cts = "2024-01-01T00:00:00.000Z",
        .sig = &(.{0xaa} ** 64),
    };
    _ = try store.insert(&label1, "e1");

    var label2 = Label{
        .src = "did:plc:labeler",
        .uri = "did:plc:other",
        .val = "bulk-mirror",
        .cts = "2024-01-01T00:00:01.000Z",
        .sig = &(.{0xbb} ** 64),
    };
    _ = try store.insert(&label2, "e2");

    const results = try store.queryBySubject(allocator, "did:plc:target");
    defer {
        for (results) |item| freeStored(allocator, item);
        allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("did:plc:target", results[0].label.uri);
}

test "store empty returns zero seq" {
    var store = try Store.init(":memory:");
    defer store.deinit();
    try std.testing.expectEqual(@as(i64, 0), store.latestSeq());
}
