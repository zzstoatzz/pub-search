const std = @import("std");
const mem = std.mem;
const json = std.json;
const Allocator = mem.Allocator;
const websocket = @import("websocket");
const zat = @import("zat");
const logfire = @import("logfire");
const poolio = @import("poolio");
const indexer = @import("indexer.zig");
const extractor = @import("extractor.zig");
const Io = std.Io;
const tpuf = @import("../tpuf.zig");

// leaflet-specific collections
const LEAFLET_DOCUMENT = "pub.leaflet.document";
const LEAFLET_PUBLICATION = "pub.leaflet.publication";

// standard.site collections (cross-platform)
const STANDARD_DOCUMENT = "site.standard.document";
const STANDARD_PUBLICATION = "site.standard.publication";
const STANDARD_RECOMMEND = "site.standard.graph.recommend";

// leaflet's parallel "interactions" lexicon. Most leaflet UI writes
// recommends here (.subject), not to the cross-platform standard one.
const LEAFLET_RECOMMEND = "pub.leaflet.interactions.recommend";

// whitewind blog entries
const WHITEWIND_ENTRY = "com.whtwnd.blog.entry";

fn isDocumentCollection(collection: []const u8) bool {
    return mem.eql(u8, collection, LEAFLET_DOCUMENT) or
        mem.eql(u8, collection, STANDARD_DOCUMENT) or
        mem.eql(u8, collection, WHITEWIND_ENTRY);
}

fn isPublicationCollection(collection: []const u8) bool {
    return mem.eql(u8, collection, LEAFLET_PUBLICATION) or
        mem.eql(u8, collection, STANDARD_PUBLICATION);
}

fn isRecommendCollection(collection: []const u8) bool {
    return mem.eql(u8, collection, STANDARD_RECOMMEND) or
        mem.eql(u8, collection, LEAFLET_RECOMMEND);
}

/// Lexicons disagree on the field name for the recommended doc:
///   site.standard.graph.recommend -> .document
///   pub.leaflet.interactions.recommend -> .subject
/// Normalize at the ingest boundary so downstream code reads one column.
fn recommendDocFieldName(collection: []const u8) []const u8 {
    return if (mem.eql(u8, collection, LEAFLET_RECOMMEND)) "subject" else "document";
}

fn getTapHost() []const u8 {
    return if (std.c.getenv("TAP_HOST")) |p| std.mem.span(p) else "leaflet-search-tap.fly.dev";
}

fn getTapPort() u16 {
    const port_str = if (std.c.getenv("TAP_PORT")) |p| std.mem.span(p) else "443";
    return std.fmt.parseInt(u16, port_str, 10) catch 443;
}

fn useTls() bool {
    return getTapPort() == 443;
}

/// Bounded queue for decoupling websocket readLoop from turso writes.
/// ACKs are sent immediately in the readLoop; processing happens in a worker thread.
/// If the queue is full (turso is slow), the OLDEST queued frame is dropped
/// (already ACK'd) so the freshest data wins.
const QUEUE_CAPACITY = 256;

const TapCtx = struct {
    allocator: Allocator,

    fn process(self: *TapCtx, _: Io, frame: []u8) void {
        defer self.allocator.free(frame);
        processMessage(self.allocator, frame) catch |err| {
            logfire.err("message processing error: {}", .{err});
        };
    }

    fn onDrop(self: *TapCtx, frame: []u8) void {
        self.allocator.free(frame);
    }
};

const TapPool = poolio.Pool([]u8, TapCtx);

pub fn consumer(allocator: Allocator, io: Io) void {
    var backoff: u64 = 1;
    const max_backoff: u64 = 30;

    while (true) {
        const connected = connect(allocator, io);
        if (connected) |_| {
            // connection succeeded then closed - reset backoff
            backoff = 1;
            logfire.info("tap connection closed, reconnecting immediately", .{});
        } else |err| {
            // connection failed - backoff
            logfire.warn("tap error: {}, reconnecting in {d}s", .{ err, backoff });
            io.sleep(Io.Duration.fromSeconds(@intCast(backoff)), .awake) catch {};
            backoff = @min(backoff * 2, max_backoff);
        }
    }
}

const Handler = struct {
    allocator: Allocator,
    io: Io,
    client: *websocket.Client,
    pool: *TapPool,
    msg_count: usize = 0,
    ack_count: usize = 0,
    no_id_count: usize = 0,
    ack_buf: [64]u8 = undefined,

    pub fn serverMessage(self: *Handler, data: []const u8) !void {
        self.msg_count += 1;
        if (self.msg_count % 1000 == 0) {
            const c = self.pool.counters(self.io);
            logfire.info("tap: recv {d}, acks {d}, accepted {d}, processed {d}, dropped {d}, queued {d}", .{
                self.msg_count, self.ack_count, c.accepted, c.processed, c.dropped, c.queued,
            });
        }

        // extract message ID for ACK
        const msg_id = extractMessageId(self.allocator, data);

        // ACK immediately — before processing — to keep TAP outbox draining.
        // processing happens asynchronously in the worker thread.
        if (msg_id) |id| {
            self.sendAck(id);
        } else {
            self.no_id_count += 1;
            if (self.no_id_count <= 5) {
                logfire.warn("tap: message has no id, first {d} bytes: {s}", .{ @min(data.len, 100), data[0..@min(data.len, 100)] });
            }
        }

        // dupe message data (websocket reuses the buffer) and offer to processing pool.
        // drop_oldest shedding means full pool evicts the oldest queued frame, not the new one.
        const data_copy = self.allocator.dupe(u8, data) catch |err| {
            logfire.err("tap: failed to dupe message: {}", .{err});
            return;
        };
        _ = self.pool.offer(self.io, data_copy);
    }

    fn sendAck(self: *Handler, msg_id: i64) void {
        const ack_json = std.fmt.bufPrint(&self.ack_buf, "{{\"type\":\"ack\",\"id\":{d}}}", .{msg_id}) catch |err| {
            logfire.err("tap: ACK format error: {}", .{err});
            return;
        };
        // log before write — websocket.zig masks the buffer in-place
        if (self.ack_count < 3) {
            logfire.info("tap: sending ACK for id={d}", .{msg_id});
        }
        self.client.write(@constCast(ack_json)) catch |err| {
            logfire.err("tap: failed to send ACK: {}", .{err});
            return;
        };
        self.ack_count += 1;
    }

    pub fn close(_: *Handler) void {}
};

fn extractMessageId(allocator: Allocator, payload: []const u8) ?i64 {
    const parsed = json.parseFromSlice(json.Value, allocator, payload, .{}) catch return null;
    defer parsed.deinit();
    return zat.json.getInt(parsed.value, "id");
}

fn connect(allocator: Allocator, io: Io) !void {
    const host = getTapHost();
    const port = getTapPort();
    const tls = useTls();
    const path = "/channel";

    logfire.info("connecting to {s}://{s}:{d}{s}", .{ if (tls) "wss" else "ws", host, port, path });

    var client = websocket.Client.init(io, allocator, .{
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

    // processing pool: decouples readLoop from turso writes so a slow/hung turso
    // request never blocks ACKs. drop_oldest shedding keeps the freshest data
    // when turso lags (older frames have already been ACK'd to the TAP outbox).
    var ctx = TapCtx{ .allocator = allocator };
    var pool = TapPool.init(allocator, .{
        .queue_capacity = QUEUE_CAPACITY,
        .workers = 1,
        .ctx = &ctx,
        .process = TapCtx.process,
        .on_drop = TapCtx.onDrop,
        .shedding = .drop_oldest,
    }) catch |err| {
        logfire.err("tap: failed to init pool: {}", .{err});
        return err;
    };
    defer pool.deinit();

    pool.start(io) catch |err| {
        logfire.err("tap: failed to start pool: {}", .{err});
        return err;
    };
    defer pool.shutdown(io);

    var handler = Handler{ .allocator = allocator, .io = io, .client = &client, .pool = &pool };
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
        logfire.span("tap.dropped", .{ .reason = "invalid_did", .collection = rec.collection }).end();
        return;
    };

    // note: bridgy fed content is no longer filtered — the indexer's HTTP site URL
    // fallback resolves base_path from the publication's "site" field, so we can
    // build working links for bridged standard.site documents.

    // build AT-URI string (no allocation - uses stack buffer)
    var uri_buf: [256]u8 = undefined;
    const uri = zat.AtUri.format(&uri_buf, did.raw, rec.collection, rec.rkey) orelse {
        logfire.span("tap.dropped", .{ .reason = "uri_too_long", .collection = rec.collection }).end();
        return;
    };

    // span for the actual indexing work
    const span = logfire.span("tap.index_record", .{});
    defer span.end();

    if (rec.isCreate() or rec.isUpdate()) {
        const inner_record = zat.json.getObject(parsed.value, "record.record") orelse {
            logfire.span("tap.dropped", .{ .reason = "no_inner_record", .collection = rec.collection, .uri = uri }).end();
            return;
        };

        if (isDocumentCollection(rec.collection)) {
            // skip author-only whitewind entries (public + url are both publicly accessible)
            if (mem.eql(u8, rec.collection, WHITEWIND_ENTRY)) {
                const record_val: json.Value = .{ .object = inner_record };
                const visibility = zat.json.getString(record_val, "visibility") orelse "public";
                if (mem.eql(u8, visibility, "author")) {
                    logfire.span("tap.dropped", .{ .reason = "author_only", .collection = rec.collection, .uri = uri }).end();
                    return;
                }
            }

            processDocument(allocator, uri, did.raw, rec.rkey, inner_record, rec.collection) catch |err| {
                logfire.err("document processing error: {}", .{err});
            };
        } else if (isPublicationCollection(rec.collection)) {
            processPublication(allocator, uri, did.raw, rec.rkey, inner_record) catch |err| {
                logfire.err("publication processing error: {}", .{err});
            };
        } else if (isRecommendCollection(rec.collection)) {
            processRecommend(uri, did.raw, rec.rkey, rec.collection, inner_record) catch |err| {
                logfire.err("recommend processing error: {}", .{err});
            };
        }
    } else if (rec.isDelete()) {
        if (isDocumentCollection(rec.collection)) {
            indexer.deleteDocument(uri);
            // also clean up turbopuffer vector (deleteDocument only handles turso)
            const hashed = tpuf.hashId(uri);
            tpuf.delete(allocator, &.{&hashed}) catch {};
        } else if (isPublicationCollection(rec.collection)) {
            indexer.deletePublication(uri);
        } else if (isRecommendCollection(rec.collection)) {
            indexer.deleteRecommend(uri);
        }
    }
}

fn processDocument(allocator: Allocator, uri: []const u8, did: []const u8, rkey: []const u8, record: json.ObjectMap, collection: []const u8) !void {
    var doc = extractor.extractDocument(allocator, record, collection) catch |err| {
        if (err == error.MissingTitle) {
            logfire.span("tap.dropped", .{ .reason = "missing_title", .collection = collection, .uri = uri }).end();
        } else if (err == error.NoContent) {
            logfire.span("tap.dropped", .{ .reason = "no_content", .collection = collection, .uri = uri }).end();
        } else {
            logfire.span("tap.dropped", .{ .reason = "extraction_error", .collection = collection, .uri = uri }).end();
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
        doc.cover_image,
    );
    logfire.counter("tap.documents_indexed", 1);
}

fn processPublication(_: Allocator, uri: []const u8, did: []const u8, rkey: []const u8, record: json.ObjectMap) !void {
    const record_val: json.Value = .{ .object = record };

    // extract required field
    const name = zat.json.getString(record_val, "name") orelse {
        logfire.span("tap.dropped", .{ .reason = "pub_missing_name", .uri = uri }).end();
        return;
    };
    const description = zat.json.getString(record_val, "description");

    // base_path: try leaflet's "base_path", then site.standard's "url"
    // url is full URL like "https://devlog.pckt.blog", we need just the host
    const base_path = zat.json.getString(record_val, "base_path") orelse
        stripUrlScheme(zat.json.getString(record_val, "url"));

    // skip .test domains (dev/staging data)
    if (base_path) |bp| {
        if (mem.endsWith(u8, bp, ".test")) {
            logfire.span("tap.dropped", .{ .reason = "test_domain", .uri = uri }).end();
            return;
        }
    }

    try indexer.insertPublication(uri, did, rkey, name, description, base_path);
    logfire.counter("tap.publications_indexed", 1);
}

fn processRecommend(uri: []const u8, did: []const u8, rkey: []const u8, collection: []const u8, record: json.ObjectMap) !void {
    const record_val: json.Value = .{ .object = record };

    const field = recommendDocFieldName(collection);
    const document_uri = zat.json.getString(record_val, field) orelse {
        logfire.span("tap.dropped", .{ .reason = "recommend_missing_document", .uri = uri, .collection = collection }).end();
        return;
    };
    const created_at = zat.json.getString(record_val, "createdAt");

    try indexer.insertRecommend(uri, did, rkey, document_uri, created_at);
    logfire.counter("tap.recommends_indexed", 1);
}

fn stripUrlScheme(url: ?[]const u8) ?[]const u8 {
    const u = url orelse return null;
    const without_scheme = if (mem.startsWith(u8, u, "https://"))
        u["https://".len..]
    else if (mem.startsWith(u8, u, "http://"))
        u["http://".len..]
    else
        u;
    // strip trailing slash to avoid double-slash when combined with path
    if (without_scheme.len > 1 and without_scheme[without_scheme.len - 1] == '/')
        return without_scheme[0 .. without_scheme.len - 1];
    return without_scheme;
}
