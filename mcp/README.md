# pub search MCP

MCP server for [pub search](https://pub-search.waow.tech) - search ATProto publishing platforms (Leaflet, pckt, Offprint, Greengale, WhiteWind, and others using standard.site).

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

## tools

| tool | description |
|------|-------------|
| `search` | search documents by query, tag, platform, or date |
| `get_document` | retrieve full content by AT-URI |
| `find_similar` | find semantically similar documents |
| `get_tags` | list all tags with document counts |
| `get_popular` | see popular search queries |
| `get_stats` | index statistics and performance metrics |

## workflow

```
search("space station") → [{uri: "at://...", title: "...", snippet: "...", url: "..."}]
get_document("at://...") → {title: "...", content: "full article text..."}
find_similar("at://...") → [{uri: "at://...", title: "...", snippet: "..."}]
```

## development

```bash
git clone https://github.com/zzstoatzz/leaflet-search
cd leaflet-search/mcp
uv sync
uv run pytest
```
