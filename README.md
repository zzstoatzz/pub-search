# leaflet-search

by [@zzstoatzz.io](https://bsky.app/profile/zzstoatzz.io)

search for [leaflet](https://leaflet.pub).

**live:** [leaflet-search.pages.dev](https://leaflet-search.pages.dev)

## how it works

1. **tap** syncs leaflet content from the network
2. **backend** indexes content into SQLite FTS5 via [Turso](https://turso.tech), serves search API
3. **site** static frontend on Cloudflare Pages

## api

```
GET /search?q=<query>&tag=<tag>  # search with query, tag, or both
GET /tags                        # list all tags with counts
GET /stats                       # document/publication counts
GET /health                      # health check
```

search returns three entity types: `article` (document in a publication), `looseleaf` (standalone document), `publication` (newsletter itself). tag filtering applies to documents only.

## stack

- [Fly.io](https://fly.io) hosts backend + tap
- [Turso](https://turso.tech) cloud SQLite with FTS5 full-text search
- [Tap](https://github.com/bluesky-social/indigo/tree/main/cmd/tap) syncs leaflet content from ATProto firehose
- [Zig](https://ziglang.org) HTTP server, search API, content indexing
- [Cloudflare Pages](https://pages.cloudflare.com) static frontend
