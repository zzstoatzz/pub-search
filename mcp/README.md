# pub search MCP

MCP server for [pub search](https://pub-search.waow.tech) - search ATProto publishing platforms (Leaflet, pckt, standard.site).

## usage

### hosted (recommended)

```bash
claude mcp add-json pub-search '{"type": "http", "url": "https://pub-search-by-zzstoatzz.fastmcp.app/mcp"}'
```

### local

run the MCP server locally with `uvx`:

```bash
uvx --from git+https://github.com/zzstoatzz/leaflet-search#subdirectory=mcp pub-search
```

to add it to claude code as a local stdio server:

```bash
claude mcp add pub-search -- uvx --from 'git+https://github.com/zzstoatzz/leaflet-search#subdirectory=mcp' pub-search
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
