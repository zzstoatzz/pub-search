const std = @import("std");
const mem = std.mem;
const json = std.json;
const posix = std.posix;
const Allocator = mem.Allocator;
const websocket = @import("websocket");
const zat = @import("zat");
const indexer = @import("indexer.zig");
const extractor = @import("extractor.zig");

// leaflet-specific collections
const LEAFLET_DOCUMENT = "pub.leaflet.document";
const LEAFLET_PUBLICATION = "pub.leaflet.publication";

// standard.site collections (cross-platform)
const STANDARD_DOCUMENT = "site.standard.document";
const STANDARD_PUBLICATION = "site.standard.publication";

fn isDocumentCollection(collection: []const u8) bool {
    return mem.eql(u8, collection, LEAFLET_DOCUMENT) or
        mem.eql(u8, collection, STANDARD_DOCUMENT);
}

fn isPublicationCollection(collection: []const u8) bool {
    return mem.eql(u8, collection, LEAFLET_PUBLICATION) or
        mem.eql(u8, collection, STANDARD_PUBLICATION);
}

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
    client: *websocket.Client,
    msg_count: usize = 0,
    ack_buf: [64]u8 = undefined,

    pub fn serverMessage(self: *Handler, data: []const u8) !void {
        self.msg_count += 1;
        if (self.msg_count % 100 == 1) {
            std.debug.print("tap: received {} messages\n", .{self.msg_count});
        }

        // extract message ID for ACK
        const msg_id = extractMessageId(self.allocator, data);

        // process the message
        processMessage(self.allocator, data) catch |err| {
            std.debug.print("message processing error: {}\n", .{err});
            // still ACK even on error to avoid infinite retries
        };

        // send ACK if we have a message ID
        if (msg_id) |id| {
            self.sendAck(id);
        }
    }

    fn sendAck(self: *Handler, msg_id: i64) void {
        const ack_json = std.fmt.bufPrint(&self.ack_buf, "{{\"type\":\"ack\",\"id\":{d}}}", .{msg_id}) catch |err| {
            std.debug.print("tap: ACK format error: {}\n", .{err});
            return;
        };
        std.debug.print("tap: sending ACK for id={d}\n", .{msg_id});
        self.client.write(@constCast(ack_json)) catch |err| {
            std.debug.print("tap: failed to send ACK: {}\n", .{err});
        };
    }

    pub fn close(_: *Handler) void {
        std.debug.print("tap connection closed\n", .{});
    }
};

fn extractMessageId(allocator: Allocator, payload: []const u8) ?i64 {
    const parsed = json.parseFromSlice(json.Value, allocator, payload, .{}) catch return null;
    defer parsed.deinit();
    return zat.json.getInt(parsed.value, "id");
}

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

    var handler = Handler{ .allocator = allocator, .client = &client };
    client.readLoop(&handler) catch |err| {
        std.debug.print("websocket read loop error: {}\n", .{err});
        return err;
    };
}

/// TAP record envelope - extracted via zat.json.extractAt
const TapRecord = struct {
    collection: []const u8,
    action: []const u8, // "create", "update", "delete"
    did: []const u8,
    rkey: []const u8,

    pub fn isCreate(self: TapRecord) bool {
        return mem.eql(u8, self.action, "create");
    }
    pub fn isUpdate(self: TapRecord) bool {
        return mem.eql(u8, self.action, "update");
    }
    pub fn isDelete(self: TapRecord) bool {
        return mem.eql(u8, self.action, "delete");
    }
};

/// Leaflet publication fields
const LeafletPublication = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    base_path: ?[]const u8 = null,
};

fn processMessage(allocator: Allocator, payload: []const u8) !void {
    const parsed = json.parseFromSlice(json.Value, allocator, payload, .{}) catch {
        std.debug.print("tap: JSON parse failed, first 100 bytes: {s}\n", .{payload[0..@min(payload.len, 100)]});
        return;
    };
    defer parsed.deinit();

    // check message type
    const msg_type = zat.json.getString(parsed.value, "type") orelse {
        std.debug.print("tap: no type field in message\n", .{});
        return;
    };

    if (!mem.eql(u8, msg_type, "record")) return;

    // extract record envelope manually (zat.extractAt was failing)
    const record_obj = zat.json.getObject(parsed.value, "record") orelse {
        std.debug.print("tap: no 'record' object in message\n", .{});
        return;
    };
    const record_val: json.Value = .{ .object = record_obj };

    const collection = zat.json.getString(record_val, "collection") orelse {
        std.debug.print("tap: record missing collection\n", .{});
        return;
    };
    const action = zat.json.getString(record_val, "action") orelse {
        std.debug.print("tap: record missing action\n", .{});
        return;
    };
    const did_str = zat.json.getString(record_val, "did") orelse {
        std.debug.print("tap: record missing did\n", .{});
        return;
    };
    const rkey = zat.json.getString(record_val, "rkey") orelse {
        std.debug.print("tap: record missing rkey\n", .{});
        return;
    };

    const rec = TapRecord{
        .collection = collection,
        .action = action,
        .did = did_str,
        .rkey = rkey,
    };

    // validate DID
    const did = zat.Did.parse(rec.did) orelse return;

    // build AT-URI string
    const uri = try std.fmt.allocPrint(allocator, "at://{s}/{s}/{s}", .{ did.raw, rec.collection, rec.rkey });
    defer allocator.free(uri);

    if (rec.isCreate() or rec.isUpdate()) {
        const inner_record = zat.json.getObject(parsed.value, "record.record") orelse return;

        if (isDocumentCollection(rec.collection)) {
            processDocument(allocator, uri, did.raw, rec.rkey, inner_record, rec.collection) catch |err| {
                std.debug.print("document processing error: {}\n", .{err});
            };
        } else if (isPublicationCollection(rec.collection)) {
            processPublication(allocator, uri, did.raw, rec.rkey, inner_record) catch |err| {
                std.debug.print("publication processing error: {}\n", .{err});
            };
        }
    } else if (rec.isDelete()) {
        if (isDocumentCollection(rec.collection)) {
            indexer.deleteDocument(uri);
            std.debug.print("deleted document: {s}\n", .{uri});
        } else if (isPublicationCollection(rec.collection)) {
            indexer.deletePublication(uri);
            std.debug.print("deleted publication: {s}\n", .{uri});
        }
    }
}

fn processDocument(allocator: Allocator, uri: []const u8, did: []const u8, rkey: []const u8, record: json.ObjectMap, collection: []const u8) !void {
    var doc = extractor.extractDocument(allocator, record, collection) catch |err| {
        if (err != error.NoContent and err != error.MissingTitle) {
            std.debug.print("extraction error for {s}: {}\n", .{ uri, err });
        }
        return;
    };
    defer doc.deinit();

    try indexer.insertDocument(
        uri,
        did,
        rkey,
        doc.title,
        doc.content,
        doc.created_at,
        doc.publication_uri,
        doc.tags,
        doc.platformName(),
        doc.source_collection,
        doc.path,
    );
    std.debug.print("indexed document: {s} [{s}] ({} chars, {} tags)\n", .{ uri, doc.platformName(), doc.content.len, doc.tags.len });
}

fn processPublication(_: Allocator, uri: []const u8, did: []const u8, rkey: []const u8, record: json.ObjectMap) !void {
    const record_val: json.Value = .{ .object = record };

    // extract required field
    const name = zat.json.getString(record_val, "name") orelse return;
    const description = zat.json.getString(record_val, "description");

    // base_path: try leaflet's "base_path", then site.standard's "url"
    // url is full URL like "https://devlog.pckt.blog", we need just the host
    const base_path = zat.json.getString(record_val, "base_path") orelse
        stripUrlScheme(zat.json.getString(record_val, "url"));

    try indexer.insertPublication(uri, did, rkey, name, description, base_path);
    std.debug.print("indexed publication: {s} (base_path: {s})\n", .{ uri, base_path orelse "none" });
}

fn stripUrlScheme(url: ?[]const u8) ?[]const u8 {
    const u = url orelse return null;
    if (mem.startsWith(u8, u, "https://")) return u["https://".len..];
    if (mem.startsWith(u8, u, "http://")) return u["http://".len..];
    return u;
}
