"""MCP server for searching ATProto publishing platforms."""

from __future__ import annotations

from typing import Any, Literal

from fastmcp import FastMCP

from pub_search._types import Document, PopularSearch, SearchResult, Stats, Tag
from pub_search.client import get_http_client

mcp = FastMCP("pub-search")


# -----------------------------------------------------------------------------
# prompts
# -----------------------------------------------------------------------------


@mcp.prompt("usage_guide")
def usage_guide() -> str:
    """instructions for using pub-search MCP tools."""
    return """\
# pub-search MCP

search ATProto publishing platforms: leaflet, pckt, offprint, greengale.

## tools

- `search(query, tag, platform, since)` - full-text search with filters
- `get_document(uri)` - fetch full content by AT-URI
- `find_similar(uri)` - semantic similarity search
- `get_tags()` - available tags
- `get_stats()` - index statistics
- `get_popular()` - popular queries

## workflow

1. `search("topic")` or `search("topic", platform="leaflet")`
2. `get_document(uri)` for full text
3. `find_similar(uri)` for related content

## result types

- **article**: document in a publication
- **looseleaf**: standalone document
- **publication**: the publication itself

results include a `url` field for web access.
"""


@mcp.prompt("search_tips")
def search_tips() -> str:
    """tips for effective searching."""
    return """\
# search tips

- prefix matching on last word: "cat dog" matches "cat dogs"
- combine filters: `search("python", tag="tutorial", platform="leaflet")`
- use `since="2025-01-01"` for recent content
- `find_similar(uri)` for semantic similarity (voyage-3-lite embeddings)
- `get_tags()` to discover available tags
"""


# -----------------------------------------------------------------------------
# tools
# -----------------------------------------------------------------------------


Platform = Literal["leaflet", "pckt", "offprint", "greengale", "other"]


@mcp.tool
async def search(
    query: str = "",
    tag: str | None = None,
    platform: Platform | None = None,
    since: str | None = None,
    limit: int = 5,
) -> list[SearchResult]:
    """search documents and publications.

    args:
        query: search query (titles and content)
        tag: filter by tag
        platform: filter by platform (leaflet, pckt, offprint, greengale, other)
        since: ISO date - only documents created after this date
        limit: max results (default 5, max 40)

    returns:
        list of results with uri, title, snippet, platform, and web url
    """
    if not query and not tag:
        return []

    params: dict[str, Any] = {}
    if query:
        params["q"] = query
    if tag:
        params["tag"] = tag
    if platform:
        params["platform"] = platform
    if since:
        params["since"] = since

    async with get_http_client() as client:
        response = await client.get("/search", params=params)
        response.raise_for_status()
        results = response.json()

    return [SearchResult(**r) for r in results[:limit]]


@mcp.tool
async def get_document(uri: str) -> Document:
    """get the full content of a document by its AT-URI.

    fetches the complete document from ATProto, including full text content.
    use this after finding documents via search to get the complete text.

    args:
        uri: the AT-URI of the document (e.g., at://did:plc:.../pub.leaflet.document/...)

    returns:
        document with full content, title, tags, and metadata
    """
    # use pdsx to fetch the actual record from ATProto
    try:
        from pdsx._internal.operations import get_record
        from pdsx.mcp.client import get_atproto_client
    except ImportError as e:
        raise RuntimeError(
            "pdsx is required for fetching full documents. install with: uv add pdsx"
        ) from e

    # extract repo from URI for PDS discovery
    # at://did:plc:xxx/collection/rkey
    parts = uri.replace("at://", "").split("/")
    if len(parts) < 3:
        raise ValueError(f"invalid AT-URI: {uri}")

    repo = parts[0]

    async with get_atproto_client(target_repo=repo) as client:
        record = await get_record(client, uri)

    value = record.value
    # DotDict doesn't have a working .get(), convert to dict first
    if hasattr(value, "to_dict") and callable(value.to_dict):
        value = value.to_dict()
    elif not isinstance(value, dict):
        value = dict(value)

    # extract content from leaflet's block structure
    # pages[].blocks[].block.plaintext
    content_parts = []
    for page in value.get("pages", []):
        for block_wrapper in page.get("blocks", []):
            block = block_wrapper.get("block", {})
            plaintext = block.get("plaintext", "")
            if plaintext:
                content_parts.append(plaintext)

    content = "\n\n".join(content_parts)

    return Document(
        uri=record.uri,
        title=value.get("title", ""),
        content=content,
        createdAt=value.get("publishedAt", "") or value.get("createdAt", ""),
        tags=value.get("tags", []),
        publicationUri=value.get("publication", ""),
    )


@mcp.tool
async def find_similar(uri: str, limit: int = 5) -> list[SearchResult]:
    """find documents similar to a given document.

    uses vector similarity (voyage-3-lite embeddings) to find semantically
    related documents. great for discovering related content after finding
    an interesting document.

    args:
        uri: the AT-URI of the document to find similar content for
        limit: max similar documents to return (default 5)

    returns:
        list of similar documents with uri, title, and metadata
    """
    async with get_http_client() as client:
        response = await client.get("/similar", params={"uri": uri})
        response.raise_for_status()
        results = response.json()

    return [SearchResult(**r) for r in results[:limit]]


@mcp.tool
async def get_tags() -> list[Tag]:
    """list all available tags with document counts.

    returns tags sorted by document count (most popular first).
    useful for discovering topics and filtering searches.

    returns:
        list of tags with their document counts
    """
    async with get_http_client() as client:
        response = await client.get("/tags")
        response.raise_for_status()
        results = response.json()

    return [Tag(**t) for t in results]


@mcp.tool
async def get_stats() -> Stats:
    """get index statistics.

    returns:
        document and publication counts
    """
    async with get_http_client() as client:
        response = await client.get("/stats")
        response.raise_for_status()
        return Stats(**response.json())


@mcp.tool
async def get_popular(limit: int = 5) -> list[PopularSearch]:
    """get popular search queries.

    see what others are searching for.
    can inspire new research directions.

    args:
        limit: max queries to return (default 5)

    returns:
        list of popular queries with search counts
    """
    async with get_http_client() as client:
        response = await client.get("/popular")
        response.raise_for_status()
        results = response.json()

    return [PopularSearch(**p) for p in results[:limit]]


# -----------------------------------------------------------------------------
# resources
# -----------------------------------------------------------------------------


@mcp.resource("pub-search://stats")
async def stats_resource() -> str:
    """current index statistics."""
    stats = await get_stats()
    return f"pub search index: {stats.documents} documents, {stats.publications} publications"


# -----------------------------------------------------------------------------
# entrypoint
# -----------------------------------------------------------------------------


def main() -> None:
    """run the MCP server."""
    mcp.run()


if __name__ == "__main__":
    main()
