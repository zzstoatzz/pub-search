# leaflet-search notes

## deployment
- **backend**: push to `main` touching `backend/**` → auto-deploys via GitHub Actions
- **frontend**: manual deploy from `site/` directory (`cd site && wrangler pages deploy . --project-name leaflet-search`)
- **tap**: manual deploy from `tap/` directory (`fly deploy --app leaflet-search-tap`)

## remotes
- `origin`: tangled.sh:zzstoatzz.io/leaflet-search
- `github`: github.com/zzstoatzz/leaflet-search (CI runs here)
- push to both: `git push origin main && git push github main`

## architecture
- **backend** (Zig): HTTP API, FTS5 search, vector similarity
- **tap**: firehose sync via bluesky-social/indigo tap
- **site**: static frontend on Cloudflare Pages
- **db**: Turso (source of truth) + local SQLite read replica (FTS queries)

## platforms
- leaflet, pckt, offprint, greengale, whitewind: known platforms
- leaflet/pckt/offprint/greengale detected via basePath; whitewind via `com.whtwnd.*` collection
- other: site.standard.* documents not from a known platform

## search ranking
- hybrid BM25 + recency: `ORDER BY rank + (days_old / 30)`
- OR between terms for recall, prefix on last word
- unicode61 tokenizer (non-alphanumeric = separator)

## tap operations
- from `tap/` directory: `just check` (status), `just turbo` (catch-up), `just normal` (steady state)
- see `docs/tap.md` for memory tuning and debugging

## zig dependencies
- update a dependency hash: `zig fetch --save <url>` (fetches and updates build.zig.zon automatically)

## schema migrations
- run via [zug](https://tangled.sh/@zzstoatzz.io/zug) — see `docs/migrations.md`
- list lives in `backend/src/db/migrations.zig`
- to add: append a new entry with the next 3-digit prefix; **never edit existing migrations** (zug checksums them)
- `BOOTSTRAP_BASELINE_COUNT` is FROZEN at 10 — don't change it when adding new migrations
- repair a dirty migration: fix the underlying issue, then `UPDATE zug_migrations SET dirty=0 WHERE id='...'` and redeploy

## MCP server
- hosted: `claude mcp add-json pub-search '{"type": "http", "url": "https://pub-search-by-zzstoatzz.fastmcp.app/mcp"}'`
- local dev: `cd pub-search-mcp && uv run pytest` for tests
- directory is `pub-search-mcp/` (NOT `mcp/`) — renamed to avoid collision with the PyPI `mcp` SDK in fastmcp.app's build template
- deployed on fastmcp.app

## common tasks
- check indexing: `curl -s https://leaflet-search-backend.fly.dev/api/dashboard | jq`
