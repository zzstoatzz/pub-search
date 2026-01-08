const std = @import("std");
const mem = std.mem;
const json = std.json;
const Allocator = mem.Allocator;
const zat = @import("zat");

/// Detected platform from collection name
pub const Platform = enum {
    leaflet,
    pckt,
    offprint,
    standardsite,
    unknown,

    pub fn fromCollection(collection: []const u8) Platform {
        if (mem.startsWith(u8, collection, "pub.leaflet.")) return .leaflet;
        if (mem.startsWith(u8, collection, "blog.pckt.")) return .pckt;
        if (mem.startsWith(u8, collection, "app.offprint.")) return .offprint;
        if (mem.startsWith(u8, collection, "site.standard.")) return .standardsite;
        return .unknown;
    }

    /// Internal name (for DB storage)
    pub fn name(self: Platform) []const u8 {
        return @tagName(self);
    }

    /// Display name (for UI)
    pub fn displayName(self: Platform) []const u8 {
        return switch (self) {
            .standardsite => "standard.site",
            else => @tagName(self),
        };
    }
};

/// Extracted document data ready for indexing.
/// All string fields are owned by this struct and must be freed via deinit().
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

    pub fn deinit(self: *ExtractedDocument) void {
        self.allocator.free(self.content);
        self.allocator.free(self.tags);
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

/// Detect platform from collection name
pub fn detectPlatform(collection: []const u8) Platform {
    return Platform.fromCollection(collection);
}

/// Extract document content from a record.
/// Caller owns the returned ExtractedDocument and must call deinit().
pub fn extractDocument(
    allocator: Allocator,
    record: json.ObjectMap,
    collection: []const u8,
) !ExtractedDocument {
    const record_val: json.Value = .{ .object = record };
    const platform = detectPlatform(collection);

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

    // extract tags - allocate owned slice
    const tags = try extractTags(allocator, record_val);
    errdefer allocator.free(tags);

    // extract content - try textContent first (standard.site), then parse blocks
    const content = try extractContent(allocator, record_val);

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

    // fall back to leaflet-style block parsing
    if (zat.json.getString(record, "description")) |desc| {
        try buf.appendSlice(allocator, desc);
    }

    if (zat.json.getArray(record, "pages")) |pages| {
        for (pages) |page| {
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

// --- tests ---

test "Platform.fromCollection: leaflet" {
    try std.testing.expectEqual(Platform.leaflet, Platform.fromCollection("pub.leaflet.document"));
    try std.testing.expectEqual(Platform.leaflet, Platform.fromCollection("pub.leaflet.publication"));
}

test "Platform.fromCollection: pckt" {
    try std.testing.expectEqual(Platform.pckt, Platform.fromCollection("blog.pckt.document"));
    try std.testing.expectEqual(Platform.pckt, Platform.fromCollection("blog.pckt.site"));
}

test "Platform.fromCollection: offprint" {
    try std.testing.expectEqual(Platform.offprint, Platform.fromCollection("app.offprint.document"));
}

test "Platform.fromCollection: standardsite" {
    try std.testing.expectEqual(Platform.standardsite, Platform.fromCollection("site.standard.document"));
    try std.testing.expectEqual(Platform.standardsite, Platform.fromCollection("site.standard.publication"));
}

test "Platform.fromCollection: unknown" {
    try std.testing.expectEqual(Platform.unknown, Platform.fromCollection("something.else"));
    try std.testing.expectEqual(Platform.unknown, Platform.fromCollection(""));
}

test "Platform.name" {
    try std.testing.expectEqualStrings("leaflet", Platform.leaflet.name());
    try std.testing.expectEqualStrings("pckt", Platform.pckt.name());
    try std.testing.expectEqualStrings("offprint", Platform.offprint.name());
    try std.testing.expectEqualStrings("standardsite", Platform.standardsite.name());
    try std.testing.expectEqualStrings("unknown", Platform.unknown.name());
}

test "Platform.displayName" {
    try std.testing.expectEqualStrings("leaflet", Platform.leaflet.displayName());
    try std.testing.expectEqualStrings("standard.site", Platform.standardsite.displayName());
}
