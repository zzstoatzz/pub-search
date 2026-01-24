# standard-search planning

expanding leaflet-search to index all standard.site records.

## references

- [standard.site](https://standard.site/) - shared lexicons for long-form publishing on ATProto
- [leaflet.pub](https://leaflet.pub/) - implements `pub.leaflet.*` lexicons
- [pckt.blog](https://pckt.blog/) - implements `blog.pckt.*` lexicons
- [offprint.app](https://offprint.app/) - implements `app.offprint.*` lexicons
- [ATProto docs](https://atproto.com/docs) - protocol documentation

## context

discussion with pckt.blog team about building global search for standard.site ecosystem.
current leaflet-search is tightly coupled to `pub.leaflet.*` lexicons.

### recent work (2026-01-05)

added similarity cache to improve `/similar` endpoint performance:
- `similarity_cache` table stores computed results keyed by `(source_uri, doc_count)`
- cache auto-invalidates when document count changes
- `/stats` endpoint now shows `cache_hits` and `cache_misses`
- first request ~3s (cold), cached requests ~0.15s

also added loading indicator for "related to" results in frontend.

### recent work (2026-01-06)

- merged PR1: multi-platform schema (platform + source_collection columns)
- added `loading.js` - portable loading state handler for dashboards
  - skeleton shimmer while loading
  - "waking up" toast after 2s threshold (fly.io cold start handling)
  - designed to be copied to other projects
- fixed pluralization ("1 result" vs "2 results")

## what we know

### standard.site lexicons

two shared lexicons for long-form publishing on ATProto:
- `site.standard.document` - document content and metadata
- `site.standard.publication` - publication/blog metadata

implementing platforms:
- leaflet.pub (`pub.leaflet.*`)
- pckt.blog (`blog.pckt.*`)
- offprint.app (`app.offprint.*`)

### site.standard.document schema

examined real records from pckt.blog. key fields:

```
textContent    - PRE-FLATTENED TEXT FOR SEARCH (the holy grail)
content        - platform-specific block structure
  .$type       - identifies platform (e.g., "blog.pckt.content")
title          - document title
tags           - array of strings
site           - AT-URI reference to site.standard.publication
path           - URL path (e.g., "/my-post-abc123")
publishedAt    - ISO timestamp
updatedAt      - ISO timestamp
coverImage     - blob reference
```

### the textContent field

this is huge. platforms flatten their block content into a single text field:

```json
{
  "content": {
    "$type": "blog.pckt.content",
    "items": [ /* platform-specific blocks */ ]
  },
  "textContent": "i have been writing a lot of atproto things in zig!..."
}
```

no need to parse platform-specific blocks - just index `textContent` directly.

### platform detection

derive platform from `content.$type` prefix:
- `blog.pckt.content` → pckt
- `pub.leaflet.content` → leaflet (TBD - need to verify)
- `app.offprint.content` → offprint (TBD - need to verify)

### current leaflet-search architecture

```
ATProto firehose (via tap)
    ↓
tap.zig - subscribes to pub.leaflet.document/publication
    ↓
indexer.zig - extracts content from nested pages[].blocks[] structure
    ↓
turso (sqlite) - documents table + FTS5 + embeddings
    ↓
search.zig - FTS5 queries + vector similarity
    ↓
server.zig - HTTP API (/search, /similar, /stats)
```

leaflet-specific code:
- tap.zig lines 10-11: hardcoded collection names
- tap.zig lines 234-268: block type extraction (pub.leaflet.blocks.*)
- recursive page/block traversal logic

generalizable code:
- database schema (FTS5, tags, stats, similarity cache)
- search/similar logic
- HTTP API
- embedding pipeline

## proposed architecture for standard-search

### ingestion changes

subscribe to:
- `site.standard.document`
- `site.standard.publication`

optionally also subscribe to platform-specific collections for richer data:
- `pub.leaflet.document/publication`
- `blog.pckt.document/publication` (if they have these)
- `app.offprint.document/publication` (if they have these)

### content extraction

for `site.standard.document`:
1. use `textContent` field directly - no block parsing!
2. fall back to title + description if textContent missing

for platform-specific records (if needed):
- keep existing leaflet block parser
- add parsers for other platforms as needed

### database changes

add to documents table:
- `platform` TEXT - derived from content.$type (leaflet, pckt, offprint)
- `source_collection` TEXT - the actual lexicon (site.standard.document, pub.leaflet.document)
- `standard_uri` TEXT - if platform-specific record, link to corresponding site.standard.document

### API changes

- `/search?q=...&platform=leaflet` - optional platform filter
- results include `platform` field
- `/similar` works across all platforms

### naming/deployment

options:
1. rename leaflet-search → standard-search (breaking change)
2. new repo/deployment, keep leaflet-search as-is
3. branch and generalize, decide naming later

leaning toward option 3 for now.

## findings from exploration

### pckt.blog - READY
- writes `site.standard.document` records
- has `textContent` field (pre-flattened)
- `content.$type` = `blog.pckt.content`
- 6+ records found on pckt.blog service account

### leaflet.pub - NOT YET MIGRATED
- still using `pub.leaflet.document` only
- no `site.standard.document` records found
- no `textContent` field - content is in nested `pages[].blocks[]`
- will need to continue parsing blocks OR wait for migration

### offprint.app - NOW INDEXED (2026-01-22)
- writes `site.standard.document` records with `app.offprint.content` blocks
- has `textContent` field (pre-flattened)
- platform detected via basePath (`*.offprint.app`, `*.offprint.test`)
- now fully supported alongside leaflet and pckt

### greengale.app - NOW INDEXED (2026-01-22)
- writes `site.standard.document` records
- has `textContent` field (pre-flattened)
- platform detected via basePath (`greengale.app/*`)
- ~29 documents indexed at time of discovery
- now fully supported alongside leaflet, pckt, and offprint

### implication for architecture

two paths:

**path A: wait for leaflet migration**
- simpler: just index `site.standard.document` with `textContent`
- all platforms converge on same schema
- downside: loses existing leaflet search until they migrate

**path B: hybrid approach**
- index `site.standard.document` (pckt, future leaflet, offprint)
- ALSO index `pub.leaflet.document` with existing block parser
- dedupe by URI or store both with `source_collection` indicator
- more complex but maintains backwards compat

leaning toward **path B** - can't lose 3500 leaflet docs.

## open questions

- [x] does leaflet write site.standard.document records? **NO, not yet**
- [x] does offprint write site.standard.document records? **UNKNOWN - no public content yet**
- [ ] when will leaflet migrate to standard.site?
- [ ] should we dedupe platform-specific vs standard records?
- [ ] embeddings: regenerate for all, or use same model?

## implementation plan (PRs)

breaking work into reviewable chunks:

### PR1: database schema for multi-platform ✅ MERGED
- add `platform TEXT` column to documents (default 'leaflet')
- add `source_collection TEXT` column (default 'pub.leaflet.document')
- backfill existing ~3500 records
- no behavior change, just schema prep
- https://github.com/zzstoatzz/leaflet-search/pull/1

### PR2: generalized content extraction
- new `extractor.zig` module with platform-agnostic interface
- `textContent` extraction for standard.site records
- keep existing block parser for `pub.leaflet.*`
- platform detection from `content.$type`

### PR3: tap subscriber for site.standard.document
- subscribe to `site.standard.document` + `site.standard.publication`
- route to appropriate extractor
- starts ingesting pckt.blog content

### PR4: API platform filter
- add `?platform=` query param to `/search`
- include `platform` field in results
- frontend: show platform badge, optional filter

### PR5 (optional, separate track): witness cache
- `witness_cache` table for raw records
- replay tooling for backfills
- independent of above work

## operational notes

- **cloudflare pages**: `leaflet-search` does NOT auto-deploy from git. manual deploy required:
  ```bash
  wrangler pages deploy site --project-name leaflet-search
  ```
- **fly.io backend**: deploy from backend directory:
  ```bash
  cd backend && fly deploy
  ```
- **git remotes**: push to both `origin` (tangled.sh) and `github` (for MCP + PRs)

## next steps

1. ~~verify leaflet's site.standard.document structure~~ (done - they don't have any)
2. ~~find and examine offprint records~~ (done - no public content yet)
3. ~~PR1: database schema~~ (merged)
4. PR2: generalized content extraction
5. PR3: tap subscriber
6. PR4: API platform filter
7. consider witness cache architecture (see below)

---

## architectural consideration: witness cache

[paul frazee's post on witness caches](https://bsky.app/profile/pfrazee.com/post/3lfarplxvcs2e) (2026-01-05):

> I'm increasingly convinced that many Atmosphere backends start with a local "witness cache" of the repositories.
>
> A witness cache is a copy of the repository records, plus a timestamp of when the record was indexed (the "witness time") which you want to keep
>
> The key feature is: you can replay it

> With local replay, you can add new tables or indexes to your backend and quickly backfill the data. If you don't have a witness cache, you would have to do backfill from the network, which is slow

### current leaflet-search architecture (no witness cache)

```
Firehose → tap → Parse & Transform → Store DERIVED data → Discard raw record
```

we store:
- `uri`, `did`, `rkey`
- `title` (extracted)
- `content` (flattened from blocks)
- `created_at`, `publication_uri`

we discard: the raw record JSON

### witness cache architecture

```
Firehose → Store RAW record + witness_time → Derive indexes on demand (replayable)
```

would store:
- `uri`, `collection`, `rkey`
- `raw_record` (full JSON blob)
- `witness_time` (when we indexed it)

then derive FTS, embeddings, etc. from local data via replay.

### comparison

| scenario | current (no cache) | with witness cache |
|----------|-------------------|-------------------|
| add new parser (offprint) | re-crawl network | replay local |
| leaflet adds textContent | wait for new records | replay & re-extract |
| fix parsing bug | re-crawl affected | replay & re-derive |
| change embedding model | re-fetch content | replay local |
| add new index/table | backfill from network | replay locally |

### trade-offs

**storage cost:**
- ~3500 docs × ~10KB avg = ~35MB (not huge)
- turso free tier: 9GB, so plenty of room

**complexity:**
- two-phase: store raw, then derive
- vs current one-phase: derive immediately

**benefits for standard-search:**
- could add offprint/pckt parsers and replay existing data
- when leaflet migrates to standard.site, re-derive without network
- embedding backfill becomes local-only (no voyage API for content fetch)

### implementation options

1. **add `raw_record TEXT` column to existing tables**
   - simple, backwards compatible
   - can migrate incrementally

2. **separate `witness_cache` table**
   - `(uri PRIMARY KEY, collection, raw_record, witness_time)`
   - cleaner separation of concerns
   - documents/publications tables become derived views

3. **use duckdb/clickhouse for witness cache** (paul's suggestion)
   - better compression for JSON blobs
   - good for analytics queries
   - adds operational complexity

for our scale, option 1 or 2 with turso is probably fine.
