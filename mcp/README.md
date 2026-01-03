# leaflet-mcp

MCP server for [Leaflet](https://leaflet.pub) - search decentralized publications on ATProto.

## usage

### hosted (recommended)

```bash
claude mcp add-json leaflet '{"type": "http", "url": "https://leaflet-search-by-zzstoatzz.fastmcp.app/mcp"}'
```

### local

run the MCP server locally with `uvx`:

```bash
uvx --from git+https://github.com/zzstoatzz/leaflet-search#subdirectory=mcp leaflet-mcp
```

to add it to claude code as a local stdio server:

```bash
claude mcp add leaflet -- uvx --from 'git+https://github.com/zzstoatzz/leaflet-search#subdirectory=mcp' leaflet-mcp
```

## workflow

1. **search** for documents by query or tag
2. **get_document** to retrieve full content by AT-URI

```
search("space station") → [{uri: "at://...", title: "...", snippet: "..."}]
get_document("at://...") → {title: "...", content: "full article text..."}
```

## development

```bash
git clone https://github.com/zzstoatzz/leaflet-search
cd leaflet-search/mcp
uv sync
uv run pytest
```
