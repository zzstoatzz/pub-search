# leaflet-search notes

## deployment
- **backend**: push to `main` touching `backend/**` → auto-deploys via GitHub Actions
- **frontend**: manual deploy only (`wrangler pages deploy site --project-name leaflet-search`)
- **tap**: manual deploy from `tap/` directory (`fly deploy --app leaflet-search-tap`)

## remotes
- `origin`: tangled.sh:zzstoatzz.io/leaflet-search
- `github`: github.com/zzstoatzz/leaflet-search (CI runs here)
- push to both: `git push origin main && git push github main`

## architecture
- **backend** (Zig): HTTP API, FTS5 search, vector similarity
- **tap**: firehose sync via bluesky-social/indigo tap
- **site**: static frontend on Cloudflare Pages
- **db**: Turso (SQLite) - FTS5 + embeddings

## search ranking
- hybrid BM25 + recency: `ORDER BY rank + (days_old / 30)`
- OR between terms for recall, prefix on last word
- unicode61 tokenizer (non-alphanumeric = separator)

## tap operations
- from `tap/` directory: `just check` (status), `just turbo` (catch-up), `just normal` (steady state)
- see `docs/tap.md` for memory tuning and debugging

## common tasks
- backfill embeddings: `./scripts/backfill-embeddings`
- check indexing: `curl -s https://leaflet-search-backend.fly.dev/api/dashboard | jq`
