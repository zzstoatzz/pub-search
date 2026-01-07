# publishing to leaflet.pub

## goal

publish markdown docs to both:
1. `site.standard.document` (for search/interop) - already working
2. `pub.leaflet.document` (for leaflet.pub display) - this plan

## the mapping

### block types

| markdown | leaflet block |
|----------|---------------|
| `# heading` | `pub.leaflet.blocks.header` (level 1-6) |
| paragraph | `pub.leaflet.blocks.text` |
| ``` code ``` | `pub.leaflet.blocks.code` |
| `> quote` | `pub.leaflet.blocks.blockquote` |
| `---` | `pub.leaflet.blocks.horizontalRule` |
| `- item` | `pub.leaflet.blocks.unorderedList` |
| `![alt](src)` | `pub.leaflet.blocks.image` (requires blob upload) |
| `[text](url)` (standalone) | `pub.leaflet.blocks.website` |

### inline formatting (facets)

leaflet uses byte-indexed facets for inline formatting within text blocks:

```json
{
  "$type": "pub.leaflet.blocks.text",
  "plaintext": "hello world with bold text",
  "facets": [{
    "index": { "byteStart": 17, "byteEnd": 21 },
    "features": [{ "$type": "pub.leaflet.richtext.facet#bold" }]
  }]
}
```

| markdown | facet type |
|----------|------------|
| `**bold**` | `pub.leaflet.richtext.facet#bold` |
| `*italic*` | `pub.leaflet.richtext.facet#italic` |
| `` `code` `` | `pub.leaflet.richtext.facet#code` |
| `[text](url)` | `pub.leaflet.richtext.facet#link` |
| `~~strike~~` | `pub.leaflet.richtext.facet#strikethrough` |

## record structure

```json
{
  "$type": "pub.leaflet.document",
  "author": "did:plc:...",
  "title": "document title",
  "description": "optional description",
  "publishedAt": "2026-01-06T00:00:00Z",
  "publication": "at://did:plc:.../pub.leaflet.publication/rkey",
  "tags": ["tag1", "tag2"],
  "pages": [{
    "$type": "pub.leaflet.pages.linearDocument",
    "id": "page-uuid",
    "blocks": [
      {
        "$type": "pub.leaflet.pages.linearDocument#block",
        "block": { /* one of the block types above */ }
      }
    ]
  }]
}
```

## implementation plan

### phase 1: markdown parser

add a simple markdown block parser to zat or the publish script:

```zig
const BlockType = enum {
    heading,
    paragraph,
    code,
    blockquote,
    horizontal_rule,
    unordered_list,
    image,
};

const Block = struct {
    type: BlockType,
    content: []const u8,
    level: ?u8 = null,        // for headings
    language: ?[]const u8 = null, // for code blocks
    alt: ?[]const u8 = null,  // for images
    src: ?[]const u8 = null,  // for images
};

fn parseMarkdownBlocks(allocator: Allocator, markdown: []const u8) ![]Block
```

parsing approach:
- split on blank lines to get blocks
- identify block type by first characters:
  - `#` → heading (count `#` for level)
  - ``` → code block (capture until closing ```)
  - `>` → blockquote
  - `---` → horizontal rule
  - `-` or `*` at start → list item
  - `![` → image
  - else → paragraph

### phase 2: inline facet extraction

for text blocks, extract inline formatting:

```zig
const Facet = struct {
    byte_start: usize,
    byte_end: usize,
    feature: FacetFeature,
};

const FacetFeature = union(enum) {
    bold,
    italic,
    code,
    link: []const u8, // url
    strikethrough,
};

fn extractFacets(allocator: Allocator, text: []const u8) !struct {
    plaintext: []const u8,
    facets: []Facet,
}
```

approach:
- scan for `**`, `*`, `` ` ``, `[`, `~~`
- track byte positions as we strip markers
- build facet list with adjusted indices

### phase 3: image blob upload

images need to be uploaded as blobs before referencing:

```zig
fn uploadImageBlob(client: *XrpcClient, allocator: Allocator, image_path: []const u8) !BlobRef
```

for now, could skip images or require them to already be uploaded.

### phase 4: json serialization

build the full `pub.leaflet.document` record:

```zig
const LeafletDocument = struct {
    @"$type": []const u8 = "pub.leaflet.document",
    author: []const u8,
    title: []const u8,
    description: ?[]const u8 = null,
    publishedAt: []const u8,
    publication: ?[]const u8 = null,
    tags: ?[][]const u8 = null,
    pages: []Page,
};

const Page = struct {
    @"$type": []const u8 = "pub.leaflet.pages.linearDocument",
    id: []const u8,
    blocks: []BlockWrapper,
};
```

### phase 5: integrate into publish-docs.zig

update the publish script to:
1. parse markdown into blocks
2. convert to leaflet structure
3. publish `pub.leaflet.document` alongside `site.standard.document`

```zig
// existing: publish site.standard.document
try putRecord(&client, allocator, session.did, "site.standard.document", tid.str(), doc_record);

// new: also publish pub.leaflet.document
const leaflet_record = try markdownToLeaflet(allocator, content, title, session.did, pub_uri);
try putRecord(&client, allocator, session.did, "pub.leaflet.document", tid.str(), leaflet_record);
```

## complexity estimate

| component | complexity | notes |
|-----------|------------|-------|
| block parsing | medium | regex-free, line-by-line |
| facet extraction | medium | byte index tracking is fiddly |
| image upload | low | already have blob upload in xrpc |
| json serialization | low | std.json handles it |
| integration | low | add to existing publish flow |

total: ~300-500 lines of zig

## open questions

1. **publication record**: do we need a `pub.leaflet.publication` too, or just documents?
   - leaflet allows standalone documents without publications
   - could skip publication for now

2. **image handling**:
   - option A: skip images initially (just text content)
   - option B: require images to be URLs (no blob upload)
   - option C: full blob upload support

3. **deduplication**: same rkey for both record types?
   - pro: easy to correlate
   - con: different collections, might not matter

4. **validation**: leaflet has a validate endpoint
   - could call `/api/unstable_validate` to check records before publish
   - probably skip for v1

## references

- [pub.leaflet.document schema](/tmp/leaflet/lexicons/pub/leaflet/document.json)
- [leaflet publishToPublication.ts](/tmp/leaflet/actions/publishToPublication.ts) - how leaflet creates records
- [site.standard.document schema](/tmp/standard.site/app/data/lexicons/document.json)
- paul's site: fetches records, doesn't publish them
