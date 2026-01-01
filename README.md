# leaflet-search

by [@zzstoatzz.io](https://bsky.app/profile/zzstoatzz.io)

full-text search for [leaflet](https://leaflet.pub) documents on the ATProto network.

**live:** [leaflet-search.pages.dev](https://leaflet-search.pages.dev)

## how it works

1. **tap** subscribes to the ATProto firehose, filtering for `pub.leaflet.document` and `pub.leaflet.publication` records
2. **backend** indexes documents into SQLite FTS5 via [Turso](https://turso.tech), serves search API
3. **site** is a static frontend hosted on Cloudflare Pages

## api

```
GET /search?q=<query>&tag=<tag>  # search with query, tag, or both
GET /tags                        # list all tags with counts
GET /stats                       # document/publication counts
GET /health                      # health check
```

search returns three entity types: `article` (document in a publication), `looseleaf` (standalone document), `publication` (newsletter itself)

## stack

- ~450 LOC of [Zig](https://ziglang.org) for the backend
- [Tap](https://github.com/bluesky-social/indigo/tree/main/cmd/tap) for ATProto sync
- [Turso](https://turso.tech) for SQLite + FTS5
- [Fly.io](https://fly.io) for hosting
- [Cloudflare Pages](https://pages.cloudflare.com) for the frontend
