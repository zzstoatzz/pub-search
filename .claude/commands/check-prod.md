# check prod health

base url: `https://leaflet-search-backend.fly.dev`

## real routes (NO `/api` prefix except where noted — defined in `backend/src/server.zig`)
- `/health` — liveness
- `/search?q=<term>` — **search uses `q`, route is `/search` (NOT `/api/search`, NOT `query=`)**
  - optional params: `&author=<handle|did>`
- `/stats`, `/tags`, `/popular`, `/recommended`, `/activity`, `/similar`
- `/dashboard`, `/api/dashboard`, `/api/timeline`, `/api/latency` (these two keep the `/api` prefix)
- `/curators`, `/recommended-by-top-authors`, `/admin/backfill`

## quick status
```bash
curl -s https://leaflet-search-backend.fly.dev/health
curl -s https://leaflet-search-backend.fly.dev/stats | jq
# /health=ok is NOT enough — exercise ALL THREE search modes. each has a
# distinct failure surface: keyword=local FTS replica, semantic=tpuf+voyage
# (gated by isSemanticEnabled = both API keys loaded), hybrid=both.
for m in keyword semantic hybrid; do
  echo -n "$m: "
  curl -s "https://leaflet-search-backend.fly.dev/search?q=atproto&format=v2&mode=$m" \
    | jq -c '.error // (.results | length)'
done
```

## observability
use the logfire MCP server to query traces and logs:
- `mcp__logfire__arbitrary_query` - run SQL against traces/spans
- `mcp__logfire__find_exceptions_in_file` - recent exceptions by file
- `mcp__logfire__schema_reference` - see available columns

## database
use turso CLI for direct SQL:
```bash
turso db shell leaf "SELECT COUNT(*) FROM documents"
turso db shell leaf "SELECT * FROM documents ORDER BY created_at DESC LIMIT 5"
```

## tap status
from `tap/` directory: `just check`
