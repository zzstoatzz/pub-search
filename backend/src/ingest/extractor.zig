const std = @import("std");
const mem = std.mem;
const json = std.json;
const Allocator = mem.Allocator;
const zat = @import("zat");

/// Detected platform from collection name
/// Note: pckt, offprint, and other platforms use site.standard.* collections.
/// Platform detection from collection only distinguishes leaflet (custom lexicon)
/// from site.standard users. Actual platform (pckt/offprint/etc) is detected later
/// from publication basePath. Documents that don't match any known platform are "other".
pub const Platform = enum {
    leaflet,
    whitewind,
    other, // site.standard.* documents not matching a known platform
    unknown,

    pub fn fromCollection(collection: []const u8) Platform {
        if (mem.startsWith(u8, collection, "pub.leaflet.")) return .leaflet;
        if (mem.startsWith(u8, collection, "site.standard.")) return .other;
        if (mem.startsWith(u8, collection, "com.whtwnd.")) return .whitewind;
        return .unknown;
    }

    /// Internal name (for DB storage)
    pub fn name(self: Platform) []const u8 {
        return @tagName(self);
    }

};

/// Extracted document data ready for indexing.
/// Only `content` and `tags` are allocated - other fields borrow from parsed JSON.
pub const ExtractedDocument = struct {
    allocator: Allocator,
    title: []const u8,
    content: []u8,
    created_at: ?[]const u8,
    publication_uri: ?[]const u8,
    tags: [][]const u8,
    platform: Platform,
    source_collection: []const u8,
    path: ?[]const u8, // URL path from record (e.g., "/001" for zat.dev)
    content_type: ?[]const u8, // content.$type (e.g., "pub.leaflet.content") for platform detection
    cover_image: ?[]const u8, // blob CID for cover image (e.g., "bafkrei...")

    pub fn deinit(self: *ExtractedDocument) void {
        self.allocator.free(self.content);
        self.allocator.free(self.tags);
    }

    /// Transfer ownership of content to caller. Caller must free returned slice.
    /// After calling, deinit() will only free tags.
    pub fn takeContent(self: *ExtractedDocument) []u8 {
        const content = self.content;
        self.content = &.{};
        return content;
    }

    /// Platform name as string (for DB storage)
    pub fn platformName(self: ExtractedDocument) []const u8 {
        return self.platform.name();
    }
};

/// Block types that have a plaintext field
const plaintext_blocks = std.StaticStringMap(void).initComptime(.{
    .{ "pub.leaflet.blocks.text", {} },
    .{ "pub.leaflet.blocks.header", {} },
    .{ "pub.leaflet.blocks.blockquote", {} },
    .{ "pub.leaflet.blocks.code", {} },
});

/// Extract document content from a record.
/// Caller owns the returned ExtractedDocument and must call deinit().
pub fn extractDocument(
    allocator: Allocator,
    record: json.ObjectMap,
    collection: []const u8,
) !ExtractedDocument {
    const record_val: json.Value = .{ .object = record };
    const platform = Platform.fromCollection(collection);

    // extract required fields
    const title = zat.json.getString(record_val, "title") orelse return error.MissingTitle;

    // extract optional fields
    const created_at = zat.json.getString(record_val, "publishedAt") orelse
        zat.json.getString(record_val, "createdAt");

    // publication/site can be a string (direct URI) or strongRef object ({uri, cid})
    // zat.json.getString supports paths like "publication.uri"
    const publication_uri = zat.json.getString(record_val, "publication") orelse
        zat.json.getString(record_val, "publication.uri") orelse
        zat.json.getString(record_val, "site") orelse
        zat.json.getString(record_val, "site.uri");

    // extract URL path (site.standard.document uses "path" field like "/001")
    const path = zat.json.getString(record_val, "path");

    // extract content.$type for platform detection (e.g., "pub.leaflet.content")
    const content_type = zat.json.getString(record_val, "content.$type");

    // extract cover image blob CID
    // try coverImage.ref.$link first (site.standard/pckt/offprint/greengale)
    const cover_image = zat.json.getString(record_val, "coverImage.ref.$link");

    // extract tags - allocate owned slice
    const tags = try extractTags(allocator, record_val);
    errdefer allocator.free(tags);

    // extract content - try textContent first (standard.site), then parse blocks
    const content = try extractContent(allocator, record_val);

    // for leaflet documents without a coverImage, try first image block
    const final_cover_image = cover_image orelse extractFirstImageCid(record_val);

    return .{
        .allocator = allocator,
        .title = title,
        .content = content,
        .created_at = created_at,
        .publication_uri = publication_uri,
        .tags = tags,
        .platform = platform,
        .source_collection = collection,
        .path = path,
        .content_type = content_type,
        .cover_image = final_cover_image,
    };
}

fn extractTags(allocator: Allocator, record: json.Value) ![][]const u8 {
    const tags_array = zat.json.getArray(record, "tags") orelse return &.{};

    var count: usize = 0;
    for (tags_array) |item| {
        if (item == .string) count += 1;
    }
    if (count == 0) return &.{};

    const tags = try allocator.alloc([]const u8, count);
    var i: usize = 0;
    for (tags_array) |item| {
        if (item == .string) {
            tags[i] = item.string;
            i += 1;
        }
    }
    return tags;
}

fn extractContent(allocator: Allocator, record: json.Value) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);

    // try textContent first (site.standard.document has this pre-flattened)
    if (zat.json.getString(record, "textContent")) |text| {
        try buf.appendSlice(allocator, text);
        return try buf.toOwnedSlice(allocator);
    }

    // try content as plain string (e.g., com.whtwnd.blog.entry stores markdown here)
    if (zat.json.getString(record, "content")) |text| {
        try buf.appendSlice(allocator, text);
        return try buf.toOwnedSlice(allocator);
    }

    // fall back to leaflet-style block parsing
    if (zat.json.getString(record, "description")) |desc| {
        try buf.appendSlice(allocator, desc);
    }

    // check for pages at top level (pub.leaflet.document)
    // or nested in content object (site.standard.document with pub.leaflet.content)
    const pages = zat.json.getArray(record, "pages") orelse
        zat.json.getArray(record, "content.pages");

    if (pages) |p| {
        for (p) |page| {
            if (page == .object) {
                try extractPageContent(allocator, &buf, page.object);
            }
        }
    }

    if (buf.items.len == 0) return error.NoContent;
    return try buf.toOwnedSlice(allocator);
}

fn extractPageContent(allocator: Allocator, buf: *std.ArrayList(u8), page: json.ObjectMap) Allocator.Error!void {
    const blocks_val = page.get("blocks") orelse return;
    if (blocks_val != .array) return;

    for (blocks_val.array.items) |wrapper| {
        if (wrapper != .object) continue;
        const block_val = wrapper.object.get("block") orelse continue;
        if (block_val != .object) continue;

        try extractBlockText(allocator, buf, block_val.object);
    }
}

fn extractBlockText(allocator: Allocator, buf: *std.ArrayList(u8), block: json.ObjectMap) Allocator.Error!void {
    const type_val = block.get("$type") orelse return;
    if (type_val != .string) return;
    const block_type = type_val.string;

    // blocks with plaintext field
    if (plaintext_blocks.has(block_type)) {
        try appendTextField(allocator, buf, block, "plaintext");
    }
    // button has text field
    else if (mem.eql(u8, block_type, "pub.leaflet.blocks.button")) {
        try appendTextField(allocator, buf, block, "text");
    }
    // list with nested children
    else if (mem.eql(u8, block_type, "pub.leaflet.blocks.unorderedList")) {
        try extractListContent(allocator, buf, block);
    }
}

fn appendTextField(allocator: Allocator, buf: *std.ArrayList(u8), obj: json.ObjectMap, field: []const u8) Allocator.Error!void {
    const val = obj.get(field) orelse return;
    if (val != .string) return;
    if (val.string.len == 0) return;

    if (buf.items.len > 0) try buf.append(allocator, ' ');
    try buf.appendSlice(allocator, val.string);
}

fn extractListContent(allocator: Allocator, buf: *std.ArrayList(u8), block: json.ObjectMap) Allocator.Error!void {
    const children = block.get("children") orelse return;
    if (children != .array) return;

    for (children.array.items) |child| {
        try extractListItem(allocator, buf, child);
    }
}

fn extractListItem(allocator: Allocator, buf: *std.ArrayList(u8), item: json.Value) Allocator.Error!void {
    if (item != .object) return;

    // list item content
    if (item.object.get("content")) |content| {
        if (content == .object) {
            try appendTextField(allocator, buf, content.object, "plaintext");
        }
    }

    // nested children (recursive)
    if (item.object.get("children")) |children| {
        if (children == .array) {
            for (children.array.items) |child| {
                try extractListItem(allocator, buf, child);
            }
        }
    }
}

/// Extract first image blob CID from leaflet-style page blocks.
/// Searches pages -> blocks for pub.leaflet.blocks.image and returns image.ref.$link.
fn extractFirstImageCid(record: json.Value) ?[]const u8 {
    // check for pages at top level or nested in content object
    const pages = zat.json.getArray(record, "pages") orelse
        zat.json.getArray(record, "content.pages") orelse
        return null;

    for (pages) |page| {
        if (page != .object) continue;
        const blocks_val = page.object.get("blocks") orelse continue;
        if (blocks_val != .array) continue;

        for (blocks_val.array.items) |wrapper| {
            if (wrapper != .object) continue;
            const block_val = wrapper.object.get("block") orelse continue;
            if (block_val != .object) continue;

            const type_val = block_val.object.get("$type") orelse continue;
            if (type_val != .string) continue;
            if (!mem.eql(u8, type_val.string, "pub.leaflet.blocks.image")) continue;

            // found an image block — extract image.ref.$link
            const image_val: json.Value = .{ .object = block_val.object };
            if (zat.json.getString(image_val, "image.ref.$link")) |cid| {
                return cid;
            }
        }
    }
    return null;
}

// --- tests ---

test "Platform.fromCollection: leaflet" {
    try std.testing.expectEqual(Platform.leaflet, Platform.fromCollection("pub.leaflet.document"));
    try std.testing.expectEqual(Platform.leaflet, Platform.fromCollection("pub.leaflet.publication"));
}

test "Platform.fromCollection: other (site.standard.*)" {
    // pckt, offprint, and others use site.standard.* collections
    // detected as "other" initially, then corrected by basePath in schema migrations
    try std.testing.expectEqual(Platform.other, Platform.fromCollection("site.standard.document"));
    try std.testing.expectEqual(Platform.other, Platform.fromCollection("site.standard.publication"));
}

test "Platform.fromCollection: whitewind" {
    try std.testing.expectEqual(Platform.whitewind, Platform.fromCollection("com.whtwnd.blog.entry"));
}

test "Platform.fromCollection: unknown" {
    try std.testing.expectEqual(Platform.unknown, Platform.fromCollection("something.else"));
    try std.testing.expectEqual(Platform.unknown, Platform.fromCollection(""));
}

test "Platform.name" {
    try std.testing.expectEqualStrings("leaflet", Platform.leaflet.name());
    try std.testing.expectEqualStrings("whitewind", Platform.whitewind.name());
    try std.testing.expectEqualStrings("other", Platform.other.name());
    try std.testing.expectEqualStrings("unknown", Platform.unknown.name());
}

test "extractDocument: site.standard.document with pub.leaflet.content" {
    const allocator = std.testing.allocator;

    // minimal site.standard.document with embedded pub.leaflet.content
    const test_json =
        \\{"title":"Test Post","content":{"$type":"pub.leaflet.content","pages":[{"id":"page1","$type":"pub.leaflet.pages.linearDocument","blocks":[{"$type":"pub.leaflet.pages.linearDocument#block","block":{"$type":"pub.leaflet.blocks.text","plaintext":"Hello world"}}]}]}}
    ;

    const parsed = try json.parseFromSlice(json.Value, allocator, test_json, .{});
    defer parsed.deinit();

    var doc = try extractDocument(allocator, parsed.value.object, "site.standard.document");
    defer doc.deinit();

    try std.testing.expectEqualStrings("Test Post", doc.title);
    try std.testing.expectEqualStrings("Hello world", doc.content);
    // content_type should be extracted for platform detection (custom domain support)
    try std.testing.expectEqualStrings("pub.leaflet.content", doc.content_type.?);
}

test "extractDocument: site.standard.document with coverImage" {
    const allocator = std.testing.allocator;

    const test_json =
        \\{"title":"Cover Test","textContent":"body text","coverImage":{"$type":"blob","ref":{"$link":"bafkreicover123"},"mimeType":"image/jpeg","size":1234}}
    ;

    const parsed = try json.parseFromSlice(json.Value, allocator, test_json, .{});
    defer parsed.deinit();

    var doc = try extractDocument(allocator, parsed.value.object, "site.standard.document");
    defer doc.deinit();

    try std.testing.expectEqualStrings("bafkreicover123", doc.cover_image.?);
}

test "extractDocument: leaflet with image block fallback" {
    const allocator = std.testing.allocator;

    const test_json =
        \\{"title":"Image Post","content":{"$type":"pub.leaflet.content","pages":[{"id":"page1","$type":"pub.leaflet.pages.linearDocument","blocks":[{"$type":"pub.leaflet.pages.linearDocument#block","block":{"$type":"pub.leaflet.blocks.text","plaintext":"Hello"}},{"$type":"pub.leaflet.pages.linearDocument#block","block":{"$type":"pub.leaflet.blocks.image","image":{"$type":"blob","ref":{"$link":"bafkreileafimg456"},"mimeType":"image/png","size":5678}}}]}]}}
    ;

    const parsed = try json.parseFromSlice(json.Value, allocator, test_json, .{});
    defer parsed.deinit();

    var doc = try extractDocument(allocator, parsed.value.object, "site.standard.document");
    defer doc.deinit();

    try std.testing.expectEqualStrings("bafkreileafimg456", doc.cover_image.?);
}

test "extractDocument: no cover image" {
    const allocator = std.testing.allocator;

    const test_json =
        \\{"title":"No Image","textContent":"just text"}
    ;

    const parsed = try json.parseFromSlice(json.Value, allocator, test_json, .{});
    defer parsed.deinit();

    var doc = try extractDocument(allocator, parsed.value.object, "site.standard.document");
    defer doc.deinit();

    try std.testing.expect(doc.cover_image == null);
}

test "extractDocument: com.whtwnd.blog.entry (whitewind)" {
    const allocator = std.testing.allocator;

    const test_json =
        \\{"title":"Love Across Discontinuity","content":"I've been thinking about what it means to love...","createdAt":"2026-02-08T08:01:41.776Z","visibility":"url"}
    ;

    const parsed = try json.parseFromSlice(json.Value, allocator, test_json, .{});
    defer parsed.deinit();

    var doc = try extractDocument(allocator, parsed.value.object, "com.whtwnd.blog.entry");
    defer doc.deinit();

    try std.testing.expectEqualStrings("Love Across Discontinuity", doc.title);
    try std.testing.expectEqualStrings("I've been thinking about what it means to love...", doc.content);
    try std.testing.expectEqualStrings("2026-02-08T08:01:41.776Z", doc.created_at.?);
    try std.testing.expectEqual(Platform.whitewind, doc.platform);
    try std.testing.expect(doc.publication_uri == null);
    try std.testing.expect(doc.content_type == null);
}
