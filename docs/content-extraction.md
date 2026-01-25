# content extraction for site.standard.document

lessons learned from implementing cross-platform content extraction.

## the problem

[eli mallon raised this question](https://bsky.app/profile/iame.li/post/3md4s4vm2os2y):

> The `site.standard.document` "content" field kinda confuses me. I see my leaflet posts have a $type field of "pub.leaflet.content". So if I were writing a renderer for site.standard.document records, presumably I'd have to know about separate things for leaflet, pckt, and offprint.

short answer: yes. but once you handle `content.pages` extraction, it's straightforward.

## textContent: platform-dependent

`site.standard.document` has a `textContent` field for pre-flattened plaintext:

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

**pckt, offprint, greengale** populate `textContent`. extraction is trivial.

**leaflet** intentionally leaves `textContent` null to avoid inflating record size. content lives in `content.pages[].blocks[].block.plaintext`.

## extraction strategy

priority order (in `extractor.zig`):

1. `textContent` - use if present
2. `pages` - top-level blocks (pub.leaflet.document)
3. `content.pages` - nested blocks (site.standard.document with pub.leaflet.content)

```zig
// try textContent first
if (zat.json.getString(record, "textContent")) |text| {
    return text;
}

// fall back to block parsing
const pages = zat.json.getArray(record, "pages") orelse
    zat.json.getArray(record, "content.pages");
```

the key insight: if you extract from `content.pages` correctly, you're good. no need for extra network calls.

## deduplication

documents can appear in both collections with identical `(did, rkey)`:
- `site.standard.document`
- `pub.leaflet.document`

handle with `ON CONFLICT`:

```sql
INSERT INTO documents (uri, ...)
ON CONFLICT(uri) DO UPDATE SET ...
```

note: leaflet is phasing out `pub.leaflet.document` records, keeping old ones for backwards compat.

## platform detection

collection name doesn't indicate platform for `site.standard.*` records. detection order:

1. **basePath** - infer from publication basePath:

| basePath contains | platform |
|-------------------|----------|
| `leaflet.pub` | leaflet |
| `pckt.blog` | pckt |
| `offprint.app` | offprint |
| `greengale.app` | greengale |

2. **content.$type** - fallback for custom domains (e.g., `cailean.journal.ewancroft.uk`):

| content.$type starts with | platform |
|---------------------------|----------|
| `pub.leaflet.` | leaflet |

3. if neither matches → `other`

## summary

- **pckt/offprint/greengale**: use `textContent` directly
- **leaflet**: extract from `content.pages[].blocks[].block.plaintext`
- **deduplication**: `ON CONFLICT` on `(did, rkey)` or `uri`
- **platform**: infer from basePath, fallback to content.$type for custom domains

## code references

- `backend/src/extractor.zig` - content extraction logic, content_type field
- `backend/src/indexer.zig:99-118` - platform detection from basePath + content_type
