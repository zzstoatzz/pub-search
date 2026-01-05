const std = @import("std");
const mem = std.mem;
const json = std.json;
const posix = std.posix;
const Allocator = mem.Allocator;
const websocket = @import("websocket");
const zat = @import("zat");
const db = @import("db/mod.zig");

const DOCUMENT_COLLECTION = "pub.leaflet.document";
const PUBLICATION_COLLECTION = "pub.leaflet.publication";

fn getTapHost() []const u8 {
    return posix.getenv("TAP_HOST") orelse "leaflet-search-tap.fly.dev";
}

fn getTapPort() u16 {
    const port_str = posix.getenv("TAP_PORT") orelse "443";
    return std.fmt.parseInt(u16, port_str, 10) catch 443;
}

fn useTls() bool {
    return getTapPort() == 443;
}

pub fn consumer(allocator: Allocator) void {
    var backoff: u64 = 1;
    const max_backoff: u64 = 30;

    while (true) {
        const connected = connect(allocator);
        if (connected) |_| {
            // connection succeeded then closed - reset backoff
            backoff = 1;
            std.debug.print("tap connection closed, reconnecting immediately...\n", .{});
        } else |err| {
            // connection failed - backoff
            std.debug.print("tap error: {}, reconnecting in {}s...\n", .{ err, backoff });
            posix.nanosleep(backoff, 0);
            backoff = @min(backoff * 2, max_backoff);
        }
    }
}

const Handler = struct {
    allocator: Allocator,
    msg_count: usize = 0,

    pub fn serverMessage(self: *Handler, data: []const u8) !void {
        self.msg_count += 1;
        if (self.msg_count % 100 == 1) {
            std.debug.print("tap: received {} messages\n", .{self.msg_count});
        }
        processMessage(self.allocator, data) catch |err| {
            std.debug.print("message processing error: {}\n", .{err});
        };
    }

    pub fn close(_: *Handler) void {
        std.debug.print("tap connection closed\n", .{});
    }
};

fn connect(allocator: Allocator) !void {
    const host = getTapHost();
    const port = getTapPort();
    const tls = useTls();
    const path = "/channel";

    std.debug.print("connecting to {s}://{s}:{d}{s}\n", .{ if (tls) "wss" else "ws", host, port, path });

    var client = websocket.Client.init(allocator, .{
        .host = host,
        .port = port,
        .tls = tls,
        .max_size = 1024 * 1024, // 1MB
    }) catch |err| {
        std.debug.print("websocket client init failed: {}\n", .{err});
        return err;
    };
    defer client.deinit();

    var host_header_buf: [256]u8 = undefined;
    const host_header = std.fmt.bufPrint(&host_header_buf, "Host: {s}\r\n", .{host}) catch host;

    client.handshake(path, .{ .headers = host_header }) catch |err| {
        std.debug.print("websocket handshake failed: {}\n", .{err});
        return err;
    };

    std.debug.print("tap connected!\n", .{});

    var handler = Handler{ .allocator = allocator };
    client.readLoop(&handler) catch |err| {
        std.debug.print("websocket read loop error: {}\n", .{err});
        return err;
    };
}

/// TAP record envelope - extracted via zat.json.extractAt
const TapRecord = struct {
    collection: []const u8,
    action: []const u8,
    did: []const u8,
    rkey: []const u8,
};

/// Leaflet document fields
const LeafletDocument = struct {
    title: []const u8,
    publication: ?[]const u8 = null,
    publishedAt: ?[]const u8 = null,
    createdAt: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

/// Leaflet publication fields
const LeafletPublication = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    base_path: ?[]const u8 = null,
};

fn processMessage(allocator: Allocator, payload: []const u8) !void {
    const parsed = json.parseFromSlice(json.Value, allocator, payload, .{}) catch return;
    defer parsed.deinit();

    // check message type
    const msg_type = zat.json.getString(parsed.value, "type") orelse return;
    if (!mem.eql(u8, msg_type, "record")) return;

    // extract record envelope
    const rec = zat.json.extractAt(TapRecord, allocator, parsed.value, .{"record"}) catch return;

    // validate DID
    const did = zat.Did.parse(rec.did) orelse return;

    // build AT-URI string
    const uri = try std.fmt.allocPrint(allocator, "at://{s}/{s}/{s}", .{ did.raw, rec.collection, rec.rkey });
    defer allocator.free(uri);

    if (mem.eql(u8, rec.action, "create") or mem.eql(u8, rec.action, "update")) {
        const record_obj = zat.json.getObject(parsed.value, "record.record") orelse return;

        if (mem.eql(u8, rec.collection, DOCUMENT_COLLECTION)) {
            processDocument(allocator, uri, did.raw, rec.rkey, record_obj) catch |err| {
                std.debug.print("document processing error: {}\n", .{err});
            };
        } else if (mem.eql(u8, rec.collection, PUBLICATION_COLLECTION)) {
            processPublication(allocator, uri, did.raw, rec.rkey, record_obj) catch |err| {
                std.debug.print("publication processing error: {}\n", .{err});
            };
        }
    } else if (mem.eql(u8, rec.action, "delete")) {
        if (mem.eql(u8, rec.collection, DOCUMENT_COLLECTION)) {
            db.deleteDocument(uri);
            std.debug.print("deleted document: {s}\n", .{uri});
        } else if (mem.eql(u8, rec.collection, PUBLICATION_COLLECTION)) {
            db.deletePublication(uri);
            std.debug.print("deleted publication: {s}\n", .{uri});
        }
    }
}

fn processDocument(allocator: Allocator, uri: []const u8, did: []const u8, rkey: []const u8, record: json.ObjectMap) !void {
    const record_val: json.Value = .{ .object = record };

    // extract known fields via struct
    const doc = zat.json.extractAt(LeafletDocument, allocator, record_val, .{}) catch return;
    const created_at = doc.publishedAt orelse doc.createdAt;

    // extract tags array
    var tags_list: std.ArrayList([]const u8) = .{};
    defer tags_list.deinit(allocator);
    if (zat.json.getArray(record_val, "tags")) |tags| {
        for (tags) |tag_item| {
            if (tag_item == .string) {
                try tags_list.append(allocator, tag_item.string);
            }
        }
    }

    // extract plaintext from pages
    var content_buf: std.ArrayList(u8) = .{};
    defer content_buf.deinit(allocator);

    if (doc.description) |desc| {
        if (desc.len > 0) {
            try content_buf.appendSlice(allocator, desc);
        }
    }

    if (zat.json.getArray(record_val, "pages")) |pages| {
        for (pages) |page| {
            if (page == .object) {
                try extractPlaintextFromPage(allocator, &content_buf, page.object);
            }
        }
    }

    if (content_buf.items.len == 0) return;

    try db.insertDocument(uri, did, rkey, doc.title, content_buf.items, created_at, doc.publication, tags_list.items);
    std.debug.print("indexed document: {s} ({} chars, {} tags)\n", .{ uri, content_buf.items.len, tags_list.items.len });
}

fn extractPlaintextFromPage(allocator: Allocator, buf: *std.ArrayList(u8), page: json.ObjectMap) !void {
    // pages can be linearDocument or canvas
    // linearDocument has blocks array
    const blocks_val = page.get("blocks") orelse return;
    if (blocks_val != .array) return;

    for (blocks_val.array.items) |block_wrapper| {
        if (block_wrapper != .object) continue;

        // block wrapper has "block" field with actual content
        const block_val = block_wrapper.object.get("block") orelse continue;
        if (block_val != .object) continue;

        try extractTextFromBlock(allocator, buf, block_val.object);
    }
}

fn extractTextFromBlock(allocator: Allocator, buf: *std.ArrayList(u8), block: json.ObjectMap) Allocator.Error!void {
    const type_val = block.get("$type") orelse return;
    if (type_val != .string) return;

    const block_type = type_val.string;

    // blocks with plaintext field: text, header, blockquote, code
    if (mem.eql(u8, block_type, "pub.leaflet.blocks.text") or
        mem.eql(u8, block_type, "pub.leaflet.blocks.header") or
        mem.eql(u8, block_type, "pub.leaflet.blocks.blockquote") or
        mem.eql(u8, block_type, "pub.leaflet.blocks.code"))
    {
        if (block.get("plaintext")) |plaintext_val| {
            if (plaintext_val == .string) {
                if (buf.items.len > 0) {
                    try buf.appendSlice(allocator, " ");
                }
                try buf.appendSlice(allocator, plaintext_val.string);
            }
        }
    }
    // button has text field
    else if (mem.eql(u8, block_type, "pub.leaflet.blocks.button")) {
        if (block.get("text")) |text_val| {
            if (text_val == .string) {
                if (buf.items.len > 0) {
                    try buf.appendSlice(allocator, " ");
                }
                try buf.appendSlice(allocator, text_val.string);
            }
        }
    }
    // unorderedList has children array with nested content
    else if (mem.eql(u8, block_type, "pub.leaflet.blocks.unorderedList")) {
        if (block.get("children")) |children_val| {
            if (children_val == .array) {
                for (children_val.array.items) |child| {
                    try extractListItemText(allocator, buf, child);
                }
            }
        }
    }
}

fn extractListItemText(allocator: Allocator, buf: *std.ArrayList(u8), item: json.Value) Allocator.Error!void {
    if (item != .object) return;

    // list item has content field which is a block
    if (item.object.get("content")) |content_val| {
        if (content_val == .object) {
            try extractTextFromBlock(allocator, buf, content_val.object);
        }
    }

    // nested children
    if (item.object.get("children")) |children_val| {
        if (children_val == .array) {
            for (children_val.array.items) |child| {
                try extractListItemText(allocator, buf, child);
            }
        }
    }
}

fn processPublication(allocator: Allocator, uri: []const u8, did: []const u8, rkey: []const u8, record: json.ObjectMap) !void {
    const record_val: json.Value = .{ .object = record };
    const pub_data = zat.json.extractAt(LeafletPublication, allocator, record_val, .{}) catch return;

    try db.insertPublication(uri, did, rkey, pub_data.name, pub_data.description, pub_data.base_path);
    std.debug.print("indexed publication: {s} (base_path: {s})\n", .{ uri, pub_data.base_path orelse "none" });
}
