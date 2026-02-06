const std = @import("std");
const mem = std.mem;
const json = std.json;
const posix = std.posix;
const Allocator = mem.Allocator;
const websocket = @import("websocket");
const zat = @import("zat");
const logfire = @import("logfire");
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
            logfire.info("tap connection closed, reconnecting immediately", .{});
        } else |err| {
            // connection failed - backoff
            logfire.warn("tap error: {}, reconnecting in {d}s", .{ err, backoff });
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
        if (self.msg_count % 1000 == 0) {
            logfire.info("tap: processed {d} messages", .{self.msg_count});
        }

        // extract message ID for ACK
        const msg_id = extractMessageId(self.allocator, data);

        // process the message
        processMessage(self.allocator, data) catch |err| {
            logfire.err("message processing error: {}", .{err});
            // still ACK even on error to avoid infinite retries
        };

        // send ACK if we have a message ID
        if (msg_id) |id| {
            self.sendAck(id);
        }
    }

    fn sendAck(self: *Handler, msg_id: i64) void {
        const ack_json = std.fmt.bufPrint(&self.ack_buf, "{{\"type\":\"ack\",\"id\":{d}}}", .{msg_id}) catch |err| {
            logfire.err("tap: ACK format error: {}", .{err});
            return;
        };
        self.client.write(@constCast(ack_json)) catch |err| {
            logfire.err("tap: failed to send ACK: {}", .{err});
        };
    }

    pub fn close(_: *Handler) void {}
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

    logfire.info("connecting to {s}://{s}:{d}{s}", .{ if (tls) "wss" else "ws", host, port, path });

    var client = websocket.Client.init(allocator, .{
        .host = host,
        .port = port,
        .tls = tls,
        .max_size = 1024 * 1024, // 1MB
    }) catch |err| {
        logfire.err("websocket client init failed: {}", .{err});
        return err;
    };
    defer client.deinit();

    var host_header_buf: [256]u8 = undefined;
    const host_header = std.fmt.bufPrint(&host_header_buf, "Host: {s}\r\n", .{host}) catch host;

    client.handshake(path, .{ .headers = host_header }) catch |err| {
        logfire.err("websocket handshake failed: {}", .{err});
        return err;
    };

    logfire.info("tap connected", .{});

    var handler = Handler{ .allocator = allocator, .client = &client };
    client.readLoop(&handler) catch |err| {
        logfire.err("websocket read loop error: {}", .{err});
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
        logfire.err("tap: JSON parse failed, first 100 bytes: {s}", .{payload[0..@min(payload.len, 100)]});
        return;
    };
    defer parsed.deinit();

    // check message type
    const msg_type = zat.json.getString(parsed.value, "type") orelse {
        logfire.warn("tap: no type field in message", .{});
        return;
    };

    if (!mem.eql(u8, msg_type, "record")) return;

    // extract record envelope (extractAt ignores extra fields like live, rev, cid)
    const rec = zat.json.extractAt(TapRecord, allocator, parsed.value, .{"record"}) catch |err| {
        logfire.warn("tap: failed to extract record: {}", .{err});
        return;
    };

    // validate DID
    const did = zat.Did.parse(rec.did) orelse {
        logfire.counter("tap.dropped.invalid_did", 1);
        return;
    };

    // build AT-URI string (no allocation - uses stack buffer)
    var uri_buf: [256]u8 = undefined;
    const uri = zat.AtUri.format(&uri_buf, did.raw, rec.collection, rec.rkey) orelse {
        logfire.counter("tap.dropped.uri_too_long", 1);
        return;
    };

    // span for the actual indexing work
    const span = logfire.span("tap.index_record", .{});
    defer span.end();

    if (rec.isCreate() or rec.isUpdate()) {
        const inner_record = zat.json.getObject(parsed.value, "record.record") orelse {
            logfire.counter("tap.dropped.no_inner_record", 1);
            return;
        };

        if (isDocumentCollection(rec.collection)) {
            processDocument(allocator, uri, did.raw, rec.rkey, inner_record, rec.collection) catch |err| {
                logfire.err("document processing error: {}", .{err});
            };
        } else if (isPublicationCollection(rec.collection)) {
            processPublication(allocator, uri, did.raw, rec.rkey, inner_record) catch |err| {
                logfire.err("publication processing error: {}", .{err});
            };
        }
    } else if (rec.isDelete()) {
        if (isDocumentCollection(rec.collection)) {
            indexer.deleteDocument(uri);
        } else if (isPublicationCollection(rec.collection)) {
            indexer.deletePublication(uri);
        }
    }
}

fn processDocument(allocator: Allocator, uri: []const u8, did: []const u8, rkey: []const u8, record: json.ObjectMap, collection: []const u8) !void {
    var doc = extractor.extractDocument(allocator, record, collection) catch |err| {
        if (err == error.MissingTitle) {
            logfire.counter("tap.dropped.missing_title", 1);
        } else if (err == error.NoContent) {
            logfire.counter("tap.dropped.no_content", 1);
        } else {
            logfire.counter("tap.dropped.extraction_error", 1);
            logfire.warn("extraction error for {s}: {}", .{ uri, err });
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
        doc.content_type,
    );
    logfire.counter("tap.documents_indexed", 1);
}

fn processPublication(_: Allocator, uri: []const u8, did: []const u8, rkey: []const u8, record: json.ObjectMap) !void {
    const record_val: json.Value = .{ .object = record };

    // extract required field
    const name = zat.json.getString(record_val, "name") orelse {
        logfire.counter("tap.dropped.pub_missing_name", 1);
        return;
    };
    const description = zat.json.getString(record_val, "description");

    // base_path: try leaflet's "base_path", then site.standard's "url"
    // url is full URL like "https://devlog.pckt.blog", we need just the host
    const base_path = zat.json.getString(record_val, "base_path") orelse
        stripUrlScheme(zat.json.getString(record_val, "url"));

    try indexer.insertPublication(uri, did, rkey, name, description, base_path);
    logfire.counter("tap.publications_indexed", 1);
}

fn stripUrlScheme(url: ?[]const u8) ?[]const u8 {
    const u = url orelse return null;
    if (mem.startsWith(u8, u, "https://")) return u["https://".len..];
    if (mem.startsWith(u8, u, "http://")) return u["http://".len..];
    return u;
}
