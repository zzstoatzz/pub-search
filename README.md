# pub search

by [@zzstoatzz.io](https://bsky.app/profile/zzstoatzz.io)

search ATProto publishing platforms ([leaflet](https://leaflet.pub), [pckt](https://pckt.blog), and others using [standard.site](https://standard.site)).

**live:** [pub-search.waow.tech](https://pub-search.waow.tech)

> formerly "leaflet-search" - generalized to support multiple publishing platforms

## how it works

1. **tap** syncs content from ATProto firehose (signals on `pub.leaflet.document`, filters `pub.leaflet.*` + `site.standard.*`)
2. **backend** indexes content into SQLite FTS5 via [Turso](https://turso.tech), serves search API
3. **site** static frontend on Cloudflare Pages

## MCP server

search is also exposed as an MCP server for AI agents like Claude Code:

```bash
claude mcp add-json pub-search '{"type": "http", "url": "https://pub-search-by-zzstoatzz.fastmcp.app/mcp"}'
```

see [mcp/README.md](mcp/README.md) for local setup and usage details.

## api

```
GET /search?q=<query>&tag=<tag>&platform=<platform>  # full-text search
GET /similar?uri=<at-uri>                            # find similar documents
GET /tags                                            # list all tags with counts
GET /popular                                         # popular search queries
GET /stats                                           # document/publication counts
GET /health                                          # health check
```

search returns three entity types: `article` (document in a publication), `looseleaf` (standalone document), `publication` (newsletter itself). each result includes a `platform` field (leaflet, pckt, etc). tag and platform filtering apply to documents only.

`/similar` uses [Voyage AI](https://voyageai.com) embeddings with brute-force cosine similarity (~0.15s for 3500 docs).

## configuration

the backend is fully configurable via environment variables:

| variable | default | description |
|----------|---------|-------------|
| `APP_NAME` | `leaflet-search` | name shown in startup logs |
| `DASHBOARD_URL` | `https://pub-search.waow.tech/dashboard.html` | redirect target for `/dashboard` |
| `TAP_HOST` | `leaflet-search-tap.fly.dev` | TAP websocket host |
| `TAP_PORT` | `443` | TAP websocket port |
| `PORT` | `3000` | HTTP server port |
| `TURSO_URL` | - | Turso database URL (required) |
| `TURSO_TOKEN` | - | Turso auth token (required) |
| `VOYAGE_API_KEY` | - | Voyage AI API key (for embeddings) |

the backend indexes multiple ATProto platforms - currently `pub.leaflet.*` and `site.standard.*` collections. platform is stored per-document and returned in search results.

## [stack](https://bsky.app/profile/zzstoatzz.io/post/3mbij5ip4ws2a)

- [Fly.io](https://fly.io) hosts backend + tap
- [Turso](https://turso.tech) cloud SQLite with vector support
- [Voyage AI](https://voyageai.com) embeddings (voyage-3-lite)
- [Tap](https://github.com/bluesky-social/indigo/tree/main/cmd/tap) syncs content from ATProto firehose
- [Zig](https://ziglang.org) HTTP server, search API, content indexing
- [Cloudflare Pages](https://pages.cloudflare.com) static frontend

## embeddings

documents are embedded using Voyage AI's `voyage-3-lite` model (512 dimensions). new documents from the firehose don't automatically get embeddings - they need to be backfilled periodically.

### backfill embeddings

requires `TURSO_URL`, `TURSO_TOKEN`, and `VOYAGE_API_KEY` in `.env`:

```bash
# check how many docs need embeddings
./scripts/backfill-embeddings --dry-run

# run the backfill (uses batching + concurrency)
./scripts/backfill-embeddings --batch-size 50
```

the script:
- fetches docs where `embedding IS NULL`
- batches them to Voyage API (50 docs/batch default)
- writes embeddings to Turso in batched transactions
- runs 8 concurrent workers

**note:** we use brute-force cosine similarity instead of a vector index. Turso's DiskANN index has ~60s write latency per row, making it impractical for incremental updates. brute-force on 3500 vectors runs in ~0.15s which is fine for this scale.
