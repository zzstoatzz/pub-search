# [pub search](https://pub-search.waow.tech)

search writing across AT Protocol publishing platforms, including [Leaflet](https://leaflet.pub), [pckt](https://pckt.blog), [Offprint](https://offprint.app), [Greengale](https://greengale.app), WhiteWind, and sites using [standard.site](https://standard.site). keyword and semantic search find documents; the [Atlas](https://pub-search.waow.tech/atlas) maps their relationships.

by [@zzstoatzz.io](https://bsky.app/profile/zzstoatzz.io).

## use

search through the [website](https://pub-search.waow.tech), the HTTP API, or the hosted MCP server:

```sh
curl -s 'https://pub-search.waow.tech/api/search?q=gardening&mode=hybrid&format=v2&limit=5'
```

```sh
claude mcp add-json pub-search '{"type":"http","url":"https://pub-search-by-zzstoatzz.fastmcp.app/mcp"}'
```

[llms.txt](https://pub-search.waow.tech/llms.txt) describes the API for agents. the [MCP package](pub-search-mcp/server/) includes local setup instructions.

## design

- **continuous ingestion** — the Zig backend consumes verified Jetstream events from stream.waow.tech through [zat](https://tangled.sh/@zzstoatzz.io/zat), extracts platform content, and writes to Turso. reconciliation checks source records to catch missed deletions.
- **local keyword reads** — an offline builder publishes verified SQLite snapshots through R2. a live overlay supplies changes between snapshots without syncing the serving replica in place.
- **search by meaning** — Voyage embeddings and turbopuffer supply semantic neighbors; hybrid search combines them with keyword results. discovery preferences and account policy govern what is shown.
- **an explorable corpus** — the Atlas projects embeddings into a map with topics, publications, and documents. topic summaries describe sampled members, disclose evidence, and can use relevant published notes as supplemental context.
- **static frontend** — Cloudflare Pages serves the UI and proxies the API. search responses use a ten-minute edge cache with thirty-minute stale-while-revalidate; background indexing and reconciliation run separately from HTTP serving on Fly.

## develop

backend builds require Zig 0.16.0. Python batch scripts use [uv](https://docs.astral.sh/uv/) and inline dependencies; the Atlas builder requires Python 3.12 or 3.13. frontend checks use Node.js.

```sh
(cd backend && zig build)                   # compile the backend
(cd backend && zig build test)              # backend tests
node --test scripts/tests/atlas-interaction.cjs scripts/tests/atlas-spacing.cjs scripts/tests/atlas-finder.mjs scripts/tests/atlas-summaries.mjs
uv run --script scripts/tests/test_judge_eval.py  # local HTTP evaluator checks
python3 -m http.server 8789                 # static preview at /site/; no API proxy
```

backend runtime credentials and service settings live in environment variables; see [backend/fly.toml](backend/fly.toml) and the source configuration. a static preview can render the Atlas when its generated datasets are present. it does not replace the deployed API proxy.

## docs

[docs/](docs/) covers architecture, API behavior, Atlas generation and history, operations, and dated investigations. [AGENTS.md](AGENTS.md) records repository workflows, including deployment and pushing both remotes.
