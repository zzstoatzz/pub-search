# content extraction for site.standard.document

lessons learned from implementing cross-platform content extraction.

## the problem

[eli mallon raised this question](https://bsky.app/profile/iame.li/post/3md4s4vm2os2y):

> The `site.standard.document` "content" field kinda confuses me. I see my leaflet posts have a $type field of "pub.leaflet.content". So if I were writing a renderer for site.standard.document records, presumably I'd have to know about separate things for leaflet, pckt, and offprint.

short answer: yes, and it's messier than the spec suggests.

## what the spec promises

`site.standard.document` has a `textContent` field that should contain pre-flattened plaintext:

```json
{
  "title": "my post",
  "textContent": "the full text content, ready for indexing...",
  "content": {
    "$type": "blog.pckt.content",
    "items": [ /* platform-specific blocks */ ]
  }
}
```

in theory, you just use `textContent` and ignore the nested `content` structure.

## what we actually found

### pckt, offprint, greengale: textContent works

these platforms properly populate `textContent`. extraction is simple:

```zig
if (zat.json.getString(record, "textContent")) |text| {
    return text;  // done
}
```

### leaflet: textContent is often empty

when `site.standard.document` has `content.$type: "pub.leaflet.content"`, the `textContent` field is frequently empty. the actual content lives in:

```
content.pages[].blocks[].block.plaintext
```

our extraction priority (in `extractor.zig`):

1. `textContent` - use if present (ideal case)
2. `pages` - parse blocks at top level (pub.leaflet.document)
3. `content.pages` - parse blocks nested in content (site.standard.document with pub.leaflet.content)

### sometimes you need a PDS fetch

when we receive a `site.standard.document` with embedded `pub.leaflet.content` but no parseable content, we fetch the corresponding `pub.leaflet.document` from the user's PDS:

```zig
// in tap.zig
if (doc.content.len == 0 and collection == STANDARD_DOCUMENT) {
    if (content_type == "pub.leaflet.content") {
        // fetch pub.leaflet.document from PDS to get actual content
        const leaflet_content = fetchLeafletContent(allocator, did, rkey);
        // ...
    }
}
```

this adds latency but ensures we don't miss content.

## deduplication

the same document can appear in both collections with identical `(did, rkey)`:
- `site.standard.document`
- `pub.leaflet.document`

we dedupe on insert - if a record with the same `(did, rkey)` exists under a different URI, we delete the old one first.

## platform detection

collection name alone doesn't tell you the platform for `site.standard.*` records. we infer from publication `basePath`:

| basePath contains | platform |
|-------------------|----------|
| `leaflet.pub` | leaflet |
| `pckt.blog` | pckt |
| `offprint.app` | offprint |
| `greengale.app` | greengale |
| (none of the above) | other |

## implications for implementers

**if you're building a renderer**: you need to understand each platform's block structure anyway, so indexing platform-specific collections (`pub.leaflet.document`, etc.) might be simpler.

**if you're building search/backlinks/RSS**: `site.standard.document` gives you a unified envelope, but:
- check `textContent` first
- fall back to parsing `content.pages` for leaflet
- consider fetching from PDS as last resort

**the wrapper pattern is useful** for cross-platform tools, but the reality is messier than "just use textContent."

## code references

- `backend/src/extractor.zig` - content extraction logic
- `backend/src/tap.zig:232-244` - PDS fetch fallback
- `backend/src/indexer.zig:99-112` - platform detection from basePath
