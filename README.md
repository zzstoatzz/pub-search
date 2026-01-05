# leaflet-search

by [@zzstoatzz.io](https://bsky.app/profile/zzstoatzz.io)

search for [leaflet](https://leaflet.pub).

**live:** [leaflet-search.pages.dev](https://leaflet-search.pages.dev)

## how it works

1. **tap** syncs leaflet content from the network
2. **backend** indexes content into SQLite FTS5 via [Turso](https://turso.tech), serves search API
3. **site** static frontend on Cloudflare Pages

## MCP server

search is also exposed as an MCP server for AI agents like Claude Code:

```bash
claude mcp add-json leaflet '{"type": "http", "url": "https://leaflet-search-by-zzstoatzz.fastmcp.app/mcp"}'
```

see [mcp/README.md](mcp/README.md) for local setup and usage details.

## api

```
GET /search?q=<query>&tag=<tag>  # search with query, tag, or both
GET /tags                        # list all tags with counts
GET /stats                       # document/publication counts
GET /health                      # health check
```

search returns three entity types: `article` (document in a publication), `looseleaf` (standalone document), `publication` (newsletter itself). tag filtering applies to documents only.

## [stack](https://bsky.app/profile/zzstoatzz.io/post/3mbij5ip4ws2a)

- [Fly.io](https://fly.io) hosts backend + tap
- [Turso](https://turso.tech) cloud SQLite
- [Tap](https://github.com/bluesky-social/indigo/tree/main/cmd/tap) syncs leaflet content from ATProto firehose
- [Zig](https://ziglang.org) HTTP server, search API, content indexing
- [Cloudflare Pages](https://pages.cloudflare.com) static frontend
