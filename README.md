# pub search

by [@zzstoatzz.io](https://bsky.app/profile/zzstoatzz.io)

search ATProto publishing platforms ([leaflet](https://leaflet.pub), [pckt](https://pckt.blog), [offprint](https://offprint.app), [greengale](https://greengale.app), and others using [standard.site](https://standard.site)).

**live:** [pub-search.waow.tech](https://pub-search.waow.tech)

> formerly "leaflet-search" - generalized to support multiple publishing platforms

## how it works

1. **[tap](https://github.com/bluesky-social/indigo/tree/main/cmd/tap)** syncs content from ATProto firehose (`pub.leaflet.*`, `site.standard.*`, `com.whtwnd.*`)
2. **backend** indexes content into SQLite FTS5 via [Turso](https://turso.tech), serves search API with keyword, semantic, and hybrid modes
3. **site** static frontend on Cloudflare Pages
4. **mcp** server for AI agents (Claude Code, etc.)

## MCP server

search is also exposed as an MCP server for AI agents like Claude Code:

```bash
claude mcp add-json pub-search '{"type": "http", "url": "https://pub-search-by-zzstoatzz.fastmcp.app/mcp"}'
```

see [pub-search-mcp/server/README.md](pub-search-mcp/server/README.md) for local setup and usage details.

## api

```
GET /search?q=<query>&mode=keyword|semantic|hybrid&platform=<platform>&tag=<tag>&since=<date>&author=<did|handle>&format=v2
GET /similar?uri=<at-uri>&format=v2
GET /tags
GET /popular
GET /stats
GET /health
```

search returns three entity types: `article` (document in a publication), `looseleaf` (standalone document), `publication` (newsletter itself). each result includes a `platform` field (leaflet, pckt, offprint, greengale, whitewind, or other). use `format=v2` for a wrapped response with `total`, `hasMore`, and `results` fields.

**modes**: `keyword` (default) uses FTS5 with BM25 + recency scoring. `semantic` uses voyage embeddings + [turbopuffer](https://turbopuffer.com) ANN. `hybrid` merges both via reciprocal rank fusion.

**ranking**: keyword results use hybrid BM25 + recency scoring. text relevance is primary, but recent documents get a boost (~1 point per 30 days). the `since` parameter filters to documents created after the given ISO date (e.g., `since=2025-01-01`).

`/similar` uses [Voyage AI](https://voyageai.com) embeddings with [turbopuffer](https://turbopuffer.com) ANN search.

## configuration

the backend is fully configurable via environment variables:

| variable | default | description |
|----------|---------|-------------|
| `APP_NAME` | `leaflet-search` | name shown in startup logs |
| `DASHBOARD_URL` | `https://pub-search.waow.tech/dashboard.html` | redirect target for `/dashboard` |
| `TAP_HOST` | `leaflet-search-tap.fly.dev` | tap websocket host |
| `TAP_PORT` | `443` | tap websocket port |
| `PORT` | `3000` | HTTP server port |
| `TURSO_URL` | - | Turso database URL (required) |
| `TURSO_TOKEN` | - | Turso auth token (required) |
| `VOYAGE_API_KEY` | - | Voyage AI API key (for embeddings) |

the backend indexes multiple ATProto platforms — currently `pub.leaflet.*`, `site.standard.*`, and `com.whtwnd.blog.entry` collections (the last for whitewind). platform is stored per-document and returned in search results.

## atlas

a 2D semantic map of the entire document index: [pub-search.waow.tech/atlas](https://pub-search.waow.tech/atlas)

documents are projected from 1024-dim voyage embeddings to 2D via PCA → UMAP, then clustered with HDBSCAN at two granularities. each point is colored by platform. zoom in to see finer cluster labels and individual document titles.

built with `scripts/build-atlas` (batch job, ~20s) → `site/atlas.json` → canvas renderer. see [docs/atlas.md](docs/atlas.md) for details.

## [stack](https://bsky.app/profile/zzstoatzz.io/post/3mbij5ip4ws2a)

- [Fly.io](https://fly.io) hosts [Zig](https://ziglang.org) search API and content indexing
- [Turso](https://turso.tech) cloud SQLite (source of truth) + local read replica (FTS queries)
- [turbopuffer](https://turbopuffer.com) ANN vector search
- [Voyage AI](https://voyageai.com) embeddings (voyage-4-lite, 1024 dims)
- [tap](https://github.com/bluesky-social/indigo/tree/main/cmd/tap) syncs content from ATProto firehose
- [Cloudflare Pages](https://pages.cloudflare.com) static frontend

## embeddings

documents are embedded using Voyage AI's `voyage-4-lite` model (1024 dimensions). the backend automatically generates embeddings for new documents via a background worker — no manual backfill needed. similarity search uses turbopuffer's ANN index for fast nearest-neighbor queries.
