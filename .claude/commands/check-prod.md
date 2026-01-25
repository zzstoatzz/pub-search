# check prod health

## quick status
```bash
curl -s https://leaflet-search-backend.fly.dev/health
curl -s https://leaflet-search-backend.fly.dev/stats | jq
```

## observability
use the logfire MCP server to query traces and logs:
- `mcp__logfire__arbitrary_query` - run SQL against traces/spans
- `mcp__logfire__find_exceptions_in_file` - recent exceptions by file
- `mcp__logfire__schema_reference` - see available columns

## database
use turso CLI for direct SQL:
```bash
turso db shell leaflet-search "SELECT COUNT(*) FROM documents"
turso db shell leaflet-search "SELECT * FROM documents ORDER BY created_at DESC LIMIT 5"
```

## tap status
from `tap/` directory: `just check`
