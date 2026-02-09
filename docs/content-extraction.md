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

## whitewind

[WhiteWind](https://whtwnd.com) (`com.whtwnd.blog.entry`) stores content as markdown in the `content` field (a string, not a blocks structure). extraction is trivial — just use the string directly. author-only posts (`visibility: "author"`) are skipped.

## deduplication

two layers prevent duplicate results:

1. **ingestion-time**: content hash (wyhash of `title + \x00 + content`) per author. if the same author publishes identical content across platforms (different rkeys), only the first is indexed.
2. **search-time**: `(did, title)` dedup collapses any remaining duplicates in results (e.g. records indexed before content hash was added).

## summary

- **pckt/offprint/greengale**: use `textContent` directly
- **leaflet**: extract from `content.pages[].blocks[].block.plaintext`
- **whitewind**: use `content` string directly (markdown)
- **deduplication**: content hash at ingestion + `(did, title)` at search time
- **platform**: infer from basePath, fallback to content.$type for custom domains

## code references

- `backend/src/ingest/extractor.zig` - content extraction logic, content_type field
- `backend/src/ingest/indexer.zig` - platform detection from basePath + content_type, content hash dedup
