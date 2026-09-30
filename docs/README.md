# how pub search works

a search engine for content published on the [AT Protocol](https://atproto.com) — the open network behind [Bluesky](https://bsky.app). it indexes posts from publishing platforms like [leaflet](https://leaflet.pub), [pckt](https://pckt.blog), [offprint](https://offprint.app), [greengale](https://greengale.app), and [whitewind](https://whtwnd.com), using standard.site, legacy Leaflet collections, or WhiteWind's own collection.

**live at [pub-search.waow.tech](https://pub-search.waow.tech)**

## the big picture

```
verified Jetstream events (stream.waow.tech)
     ↓ archive recovery + live subscription through zat
backend (Zig)
     ├── Turso (source of truth)
     ├── local SQLite snapshot + live overlay (FTS5)
     │      ↑ offline builder → R2 manifest → verified adoption
     ├── Voyage embeddings → turbopuffer (semantic search)
     └── HTTP API → Cloudflare Pages proxy → frontend / MCP
```

[Ingestion](jetstream-cutover.md) extracts publishing records and applies account
policy before indexing. The serving replica is built off-host and adopted rather
than synced in place; an [overlay](overlay-serving.md) supplies live changes.
A [reconciler](reconciliation.md) checks source records and schedules bounded
retries so unavailable sources cannot monopolize verification.

The [Atlas](atlas.md) projects the vector index into an interactive map. Its
summaries use sampled documents with optional related context; map/summary pairs
are archived for later analysis. See [frontend.md](frontend.md) for loading,
preview, and release checks.

## how searching works

there are three search modes, each using different technology:

### keyword search

uses [SQLite FTS5](https://www.sqlite.org/fts5.html) — a built-in full-text search engine. when a document is indexed, FTS5 builds an inverted index (a map from every word to every document containing it). queries use [BM25](https://en.wikipedia.org/wiki/Okapi_BM25) ranking — a standard relevance scoring algorithm that considers term frequency and document length. recent documents get a small boost.

this is not something custom — FTS5 is a well-established tool built into SQLite. the custom part is building the index (deciding what to index, how to tokenize, how to rank) and the query syntax (OR between terms for recall, prefix matching on the last word for a type-ahead feel).

keyword search merges the **local SQLite snapshot and live overlay**. broad unfiltered queries use a bounded candidate pass so common terms do not require full-corpus document probes.

### semantic search

uses [Voyage AI](https://voyageai.com) embeddings (voyage-4-lite, 1024 dimensions) to convert text into vectors — arrays of numbers that capture meaning. similar texts produce similar vectors, even if they don't share any words.

these vectors are stored in [turbopuffer](https://turbopuffer.com), a vector database optimized for approximate nearest-neighbor (ANN) search. when you search semantically, your query is embedded into a vector, and turbopuffer finds the documents whose vectors are closest.

this is how a search for `"loosely about cooking"` can find a post titled `"my grandmother's kitchen"` — keyword search would miss it entirely because the words don't overlap, but the meaning is close.

### hybrid search

runs both keyword and semantic in parallel, then merges results using [reciprocal rank fusion](https://plg.uwaterloo.ca/~gvcormac/cormacksigir09-rrf.pdf) (RRF, k=60). documents found by both methods rank highest. each result is annotated with its source: `"keyword"`, `"semantic"`, or `"keyword+semantic"`.

## the content extraction problem

every platform on standard.site stores document content differently. this is the most fiddly part of the system.

- **pckt, offprint, greengale** provide a `textContent` field with pre-flattened plaintext — easy
- **leaflet** omits `textContent` to save record size. content lives nested inside `content.pages[].blocks[].block.plaintext` — requires block-by-block extraction
- **whitewind** stores markdown directly in a `content` string field

the backend handles all of this in the [content extraction](content-extraction.md) layer, producing a uniform plaintext blob for indexing regardless of source platform.

## what's custom vs off-the-shelf

| component | off-the-shelf | custom |
|-----------|---------------|--------|
| full-text matching | SQLite FTS5 (BM25 ranking, inverted index) | query construction, tokenization rules, recency scoring |
| vector similarity | Voyage AI (embeddings), turbopuffer (ANN search) | hybrid fusion, result merging, snippet extraction |
| event ingestion | [zat](https://tangled.sh/@zzstoatzz.io/zat) Jetstream SDK; upstream Sync 1.1 verification | durable cursor, corpus policy, content extraction per platform |
| data storage | Turso (cloud SQLite), local SQLite replica, R2 (snapshot artifacts) | schema design, snapshot builder + manifest gates, replica adoption |
| schema migrations | [zug](https://tangled.sh/@zzstoatzz.io/zug) (Zig 0.16 SQLite migration runner) | migration list, bootstrap path for the existing turso DB, `MigrationConn` adapter to zug's connection trait |
| frontend | Cloudflare Pages (hosting) | the entire UI and search experience |

the tools are popular and well-established. the assembly — wiring the firehose to content extraction to multi-modal search across heterogeneous publishing platforms — is very custom.

## further reading

- [search-syntax.md](search-syntax.md) — query syntax reference (quotes, OR, filters, modes)
- [search-architecture.md](search-architecture.md) — FTS5 details, scaling considerations, future options
- [content-extraction.md](content-extraction.md) — how content is extracted from each platform
- [api.md](api.md) — API endpoint reference
- [exclusions.md](exclusions.md) — the registry of manually excluded authors: the policy line (composed vs generated), enforcement layers, and the evidence for each ban
- [spam-detection-plan.md](spam-detection-plan.md) — the labeler: pub-search autonomously labels accounts that generate documents from datasets (`bulk-generated`, see [/labels](https://pub-search.waow.tech/labels)); doc is the original plan with an as-built status header
- [retro-2026-09-05-rescore-label-spill.md](retro-2026-09-05-rescore-label-spill.md) — a scoring rescore wiped `author_stats` and un-labeled every bulk-generated account for 25 minutes; a rescore now rebuilds counters in place and never drops a verdict
- [retro-2026-09-05-keyword-second-match-scan.md](retro-2026-09-05-keyword-second-match-scan.md) — snippet-producing keyword statements re-ran the MATCH as a second full scan (17s for "the", 42 minutes for "a"); one MATCH per statement now, snippets built from the document text
- [agent-surfaces.md](agent-surfaces.md) — adopting pub-search for agents: MCP vs HTTP API, when to use which
- [snapshot-pipeline.md](snapshot-pipeline.md) — how the keyword index ships (builder → manifest → R2 → verified adoption), what scales, and how to do production data surgery
- [scaling-plan.md](scaling-plan.md) — the plan of record: snapshot builder → R2 → verified swap → live overlay (largely executed; see status header)
- [retro-2026-06-10-cutover-cascade.md](retro-2026-06-10-cutover-cascade.md) — the outage night that produced the invariants behind that plan
- [reconciliation.md](reconciliation.md) — stale document detection and cleanup
- [turso-hrana.md](turso-hrana.md) — Turso's HTTP protocol for database queries
- [migrations.md](migrations.md) — schema migration system (zug + adapter + bootstrap)
- [performance-saga.md](performance-saga.md) — a debugging story about latency spikes
- [access-pattern-audit.md](access-pattern-audit.md) — a debugging story about turso row-read cost (the cost-side companion to the latency saga)
