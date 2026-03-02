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
const tpuf = @import("../tpuf.zig");

// leaflet-specific collections
const LEAFLET_DOCUMENT = "pub.leaflet.document";
const LEAFLET_PUBLICATION = "pub.leaflet.publication";

// standard.site collections (cross-platform)
const STANDARD_DOCUMENT = "site.standard.document";
const STANDARD_PUBLICATION = "site.standard.publication";

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

/// Bounded queue for decoupling websocket readLoop from turso writes.
/// ACKs are sent immediately in the readLoop; processing happens in a worker thread.
/// If the queue is full (turso is slow), new messages are dropped (already ACK'd).
const QUEUE_CAPACITY = 256;

const ProcessQueue = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    items: [QUEUE_CAPACITY]?[]u8 = .{null} ** QUEUE_CAPACITY,
    head: usize = 0,
    tail: usize = 0,
    len: usize = 0,
    stopped: bool = false,
    allocator: Allocator,
    dropped: usize = 0,
    processed: usize = 0,

    fn push(self: *ProcessQueue, data: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.len == QUEUE_CAPACITY) {
            // queue full — drop oldest (already ACK'd)
            if (self.items[self.head]) |old| {
                self.allocator.free(old);
            }
            self.head = (self.head + 1) % QUEUE_CAPACITY;
            self.len -= 1;
            self.dropped += 1;
            if (self.dropped <= 5 or self.dropped % 100 == 0) {
                logfire.warn("tap: queue full, dropped {d} messages total", .{self.dropped});
            }
        }

        self.items[self.tail] = data;
        self.tail = (self.tail + 1) % QUEUE_CAPACITY;
        self.len += 1;
        self.cond.signal();
    }

    fn pop(self: *ProcessQueue) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.len == 0 and !self.stopped) {
            self.cond.wait(&self.mutex);
        }

        if (self.len == 0) return null; // stopped with empty queue

        const data = self.items[self.head].?;
        self.items[self.head] = null;
        self.head = (self.head + 1) % QUEUE_CAPACITY;
        self.len -= 1;
        return data;
    }

    fn stop(self: *ProcessQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopped = true;
        self.cond.signal();
    }

    fn drain(self: *ProcessQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.items) |*item| {
            if (item.*) |data| {
                self.allocator.free(data);
                item.* = null;
            }
        }
    }
};

/// Cache of DID → is_bridgy_fed results from PLC directory lookups.
/// Single-threaded (owned by processWorker), no sync needed.
const PdsCache = std.StringHashMap(bool);

fn processWorker(queue: *ProcessQueue) void {
    logfire.info("tap: process worker started", .{});
    var pds_cache = PdsCache.init(queue.allocator);
    defer {
        var it = pds_cache.iterator();
        while (it.next()) |entry| queue.allocator.free(entry.key_ptr.*);
        pds_cache.deinit();
    }
    while (queue.pop()) |data| {
        defer queue.allocator.free(data);
        processMessage(queue.allocator, data, &pds_cache) catch |err| {
            logfire.err("message processing error: {}", .{err});
        };
        queue.mutex.lock();
        queue.processed += 1;
        queue.mutex.unlock();
    }
    logfire.info("tap: process worker stopped (processed {d}, dropped {d})", .{ queue.processed, queue.dropped });
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
    queue: *ProcessQueue,
    msg_count: usize = 0,
    ack_count: usize = 0,
    no_id_count: usize = 0,
    ack_buf: [64]u8 = undefined,

    pub fn serverMessage(self: *Handler, data: []const u8) !void {
        self.msg_count += 1;
        if (self.msg_count % 1000 == 0) {
            logfire.info("tap: recv {d}, acks {d}, processed {d}, dropped {d}, queued {d}", .{
                self.msg_count, self.ack_count, self.queue.processed, self.queue.dropped, self.queue.len,
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

        // dupe message data (websocket reuses the buffer) and push to processing queue
        const data_copy = self.allocator.dupe(u8, data) catch |err| {
            logfire.err("tap: failed to dupe message: {}", .{err});
            return;
        };
        self.queue.push(data_copy);
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

    // processing queue + worker thread: decouples readLoop from turso writes
    // so a slow/hung turso request never blocks ACKs
    var queue = ProcessQueue{ .allocator = allocator };
    const worker = std.Thread.spawn(.{}, processWorker, .{&queue}) catch |err| {
        logfire.err("tap: failed to spawn process worker: {}", .{err});
        return err;
    };
    defer {
        queue.stop();
        worker.join();
        queue.drain();
    }

    var handler = Handler{ .allocator = allocator, .client = &client, .queue = &queue };
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

/// Check if a DID is hosted on brid.gy (bridged Mastodon/ActivityPub/Ghost content).
/// Results are cached for the lifetime of the worker thread.
/// Fails open: on HTTP/parse errors, returns false (allow through).
fn isBridgyFed(allocator: Allocator, did: []const u8, cache: *PdsCache) bool {
    if (cache.get(did)) |is_bridgy| return is_bridgy;

    const result = resolvePdsIsBridgy(allocator, did);
    // cache with duped key (cache outlives the parsed message)
    const key = allocator.dupe(u8, did) catch return false;
    cache.put(key, result) catch {
        allocator.free(key);
        return result;
    };
    if (result) {
        logfire.info("tap: blocked bridgy fed DID: {s}", .{did});
    }
    return result;
}

/// HTTP GET plc.directory/{did}, check if PDS serviceEndpoint contains "brid.gy".
fn resolvePdsIsBridgy(allocator: Allocator, did: []const u8) bool {
    const http = std.http;

    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://plc.directory/{s}", .{did}) catch return false;

    var client: http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_body.writer,
    }) catch |err| {
        logfire.warn("tap: PLC lookup failed for {s}: {}", .{ did, err });
        return false;
    };

    if (res.status != .ok) {
        logfire.warn("tap: PLC lookup {s} returned {}", .{ did, res.status });
        return false;
    }

    const body = response_body.toOwnedSlice() catch return false;
    defer allocator.free(body);

    const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch return false;
    defer parsed.deinit();

    // look for service[].serviceEndpoint where type == "AtprotoPersonalDataServer"
    const services = parsed.value.object.get("service") orelse return false;
    if (services != .array) return false;

    for (services.array.items) |svc| {
        if (svc != .object) continue;
        const svc_type = svc.object.get("type") orelse continue;
        if (svc_type != .string) continue;
        if (!mem.eql(u8, svc_type.string, "AtprotoPersonalDataServer")) continue;
        const endpoint = svc.object.get("serviceEndpoint") orelse continue;
        if (endpoint != .string) continue;
        if (mem.indexOf(u8, endpoint.string, "brid.gy") != null) return true;
    }

    return false;
}

fn processMessage(allocator: Allocator, payload: []const u8, pds_cache: *PdsCache) !void {
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

    // skip bridgy fed content (bridged Mastodon/ActivityPub/Ghost posts)
    if (isDocumentCollection(rec.collection) or isPublicationCollection(rec.collection)) {
        if (isBridgyFed(allocator, did.raw, pds_cache)) {
            logfire.span("tap.dropped", .{ .reason = "bridgy_fed", .collection = rec.collection }).end();
            return;
        }
    }

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
        }
    } else if (rec.isDelete()) {
        if (isDocumentCollection(rec.collection)) {
            indexer.deleteDocument(uri);
            // also clean up turbopuffer vector (deleteDocument only handles turso)
            const hashed = tpuf.hashId(uri);
            tpuf.delete(allocator, &.{&hashed}) catch {};
        } else if (isPublicationCollection(rec.collection)) {
            indexer.deletePublication(uri);
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
