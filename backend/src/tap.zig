const std = @import("std");
const mem = std.mem;
const json = std.json;
const posix = std.posix;
const Allocator = mem.Allocator;
const websocket = @import("websocket");
const db = @import("db/mod.zig");

const DOCUMENT_COLLECTION = "pub.leaflet.document";
const PUBLICATION_COLLECTION = "pub.leaflet.publication";

// domain types
const Did = struct {
    raw: []const u8,

    fn parse(s: []const u8) ?Did {
        if (!mem.startsWith(u8, s, "did:")) return null;
        const rest = s[4..];
        const colon = mem.indexOf(u8, rest, ":") orelse return null;
        if (colon == 0 or colon == rest.len - 1) return null;
        return .{ .raw = s };
    }

    fn str(self: Did) []const u8 {
        return self.raw;
    }
};

const AtUri = struct {
    raw: []const u8,
    did_end: usize,
    collection_end: usize,

    fn build(allocator: Allocator, d: Did, coll: []const u8, rk: []const u8) !AtUri {
        const raw = try std.fmt.allocPrint(allocator, "at://{s}/{s}/{s}", .{ d.raw, coll, rk });
        return .{
            .raw = raw,
            .did_end = 5 + d.raw.len,
            .collection_end = 5 + d.raw.len + 1 + coll.len,
        };
    }

    fn did(self: AtUri) Did {
        return .{ .raw = self.raw[5..self.did_end] };
    }

    fn rkey(self: AtUri) []const u8 {
        return self.raw[self.collection_end + 1 ..];
    }

    fn str(self: AtUri) []const u8 {
        return self.raw;
    }
};

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

fn processMessage(allocator: Allocator, payload: []const u8) !void {
    const parsed = json.parseFromSlice(json.Value, allocator, payload, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value.object;

    // tap format: { "id": 123, "type": "record", "record": { ... } }
    const msg_type = root.get("type") orelse return;
    if (msg_type != .string) return;
    if (!mem.eql(u8, msg_type.string, "record")) return;

    const record_wrapper = root.get("record") orelse return;
    if (record_wrapper != .object) return;

    const rec = record_wrapper.object;

    const collection = rec.get("collection") orelse return;
    if (collection != .string) return;

    const action = rec.get("action") orelse return;
    if (action != .string) return;

    const did_val = rec.get("did") orelse return;
    if (did_val != .string) return;
    const did = Did.parse(did_val.string) orelse return;

    const rkey = rec.get("rkey") orelse return;
    if (rkey != .string) return;

    const uri = AtUri.build(allocator, did, collection.string, rkey.string) catch return;
    defer allocator.free(uri.raw);

    if (mem.eql(u8, action.string, "create") or mem.eql(u8, action.string, "update")) {
        const record = rec.get("record") orelse return;
        if (record != .object) return;

        if (mem.eql(u8, collection.string, DOCUMENT_COLLECTION)) {
            processDocument(allocator, uri, record.object) catch |err| {
                std.debug.print("document processing error: {}\n", .{err});
            };
        } else if (mem.eql(u8, collection.string, PUBLICATION_COLLECTION)) {
            processPublication(uri, record.object) catch |err| {
                std.debug.print("publication processing error: {}\n", .{err});
            };
        }
    } else if (mem.eql(u8, action.string, "delete")) {
        if (mem.eql(u8, collection.string, DOCUMENT_COLLECTION)) {
            db.deleteDocument(uri.str());
            std.debug.print("deleted document: {s}\n", .{uri.str()});
        } else if (mem.eql(u8, collection.string, PUBLICATION_COLLECTION)) {
            db.deletePublication(uri.str());
            std.debug.print("deleted publication: {s}\n", .{uri.str()});
        }
    }
}

fn processDocument(allocator: Allocator, uri: AtUri, record: json.ObjectMap) !void {
    // get title
    const title_val = record.get("title") orelse return;
    if (title_val != .string) return;
    const title = title_val.string;

    // get publication URI
    const publication_uri: ?[]const u8 = blk: {
        if (record.get("publication")) |v| {
            if (v == .string) break :blk v.string;
        }
        break :blk null;
    };

    // get createdAt (optional, might be publishedAt)
    const created_at: ?[]const u8 = blk: {
        if (record.get("publishedAt")) |v| {
            if (v == .string) break :blk v.string;
        }
        if (record.get("createdAt")) |v| {
            if (v == .string) break :blk v.string;
        }
        break :blk null;
    };

    // extract tags
    var tags_list: std.ArrayList([]const u8) = .{};
    defer tags_list.deinit(allocator);
    if (record.get("tags")) |tags_val| {
        if (tags_val == .array) {
            for (tags_val.array.items) |tag_item| {
                if (tag_item == .string) {
                    try tags_list.append(allocator, tag_item.string);
                }
            }
        }
    }

    var content_buf: std.ArrayList(u8) = .{};
    defer content_buf.deinit(allocator);

    // include document description if present
    if (record.get("description")) |desc_val| {
        if (desc_val == .string and desc_val.string.len > 0) {
            try content_buf.appendSlice(allocator, desc_val.string);
        }
    }

    // extract plaintext from pages
    if (record.get("pages")) |pages_val| {
        if (pages_val == .array) {
            for (pages_val.array.items) |page| {
                if (page != .object) continue;
                try extractPlaintextFromPage(allocator, &content_buf, page.object);
            }
        }
    }

    if (content_buf.items.len == 0) {
        // no content extracted, skip
        return;
    }

    try db.insertDocument(uri.str(), uri.did().str(), uri.rkey(), title, content_buf.items, created_at, publication_uri, tags_list.items);
    std.debug.print("indexed document: {s} ({} chars, {} tags)\n", .{ uri.str(), content_buf.items.len, tags_list.items.len });
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

fn processPublication(uri: AtUri, record: json.ObjectMap) !void {
    const name_val = record.get("name") orelse return;
    if (name_val != .string) return;
    const name = name_val.string;

    const description: ?[]const u8 = blk: {
        if (record.get("description")) |v| {
            if (v == .string) break :blk v.string;
        }
        break :blk null;
    };

    const base_path: ?[]const u8 = blk: {
        if (record.get("base_path")) |v| {
            if (v == .string) break :blk v.string;
        }
        break :blk null;
    };

    try db.insertPublication(uri.str(), uri.did().str(), uri.rkey(), name, description, base_path);
    std.debug.print("indexed publication: {s} (base_path: {s})\n", .{ uri.str(), base_path orelse "none" });
}
