# leaflet-mcp

MCP server for [Leaflet](https://leaflet.pub) - search decentralized publications on ATProto.

## installation

```bash
uv add leaflet-mcp
```

## usage

### as a CLI

```bash
leaflet-mcp
```

### with Claude Code

Add to your `.claude/settings.json`:

```json
{
  "mcpServers": {
    "leaflet": {
      "command": "uvx",
      "args": ["leaflet-mcp"]
    }
  }
}
```

## tools

- `search(query, tag, limit)` - search documents and publications
- `get_document(uri)` - get full document content by AT-URI
- `find_similar(uri, limit)` - find semantically similar documents
- `get_tags()` - list available tags with counts
- `get_stats()` - get index statistics
- `get_popular(limit)` - get popular search queries

## example

```python
from fastmcp.client import Client
from fastmcp.client.transports import SSETransport

async with Client(transport=SSETransport("http://localhost:8000/sse")) as client:
    # search for python articles
    results = await client.call_tool("search", {"query": "python"})

    # get full content of first result
    if results.data:
        doc = await client.call_tool("get_document", {"uri": results.data[0].uri})
        print(doc.data.content)
```

## development

```bash
# install dev dependencies
uv sync --group dev

# run tests
uv run pytest

# format
uv run ruff format
```
