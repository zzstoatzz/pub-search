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

- `search(query, tag, platform, since)` - keyword search with filters
- `search_semantic(query)` - meaning-based search (natural language queries)
- `search_hybrid(query)` - combined keyword + semantic with source annotations
- `get_document(uri)` - fetch full content by AT-URI
- `find_similar(uri)` - find related documents
- `get_tags()` - available tags
- `get_stats()` - index statistics
- `get_popular()` - popular queries

## workflow

1. `search("topic")` for keyword search, `search_hybrid("topic")` for best results
2. `get_document(uri)` for full text
3. `find_similar(uri)` for related content

## search modes

- **keyword**: fast exact match (~100ms), supports tag/since filters
- **semantic**: meaning-based (~500ms), good for natural language queries
- **hybrid**: both combined with rank fusion, `source` field shows how each result was found

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
- `search_semantic("natural language query")` for meaning-based search
- `search_hybrid("query")` for best of both — results show `source` field
- `find_similar(uri)` to discover related documents
- `get_tags()` to discover available tags
"""


# -----------------------------------------------------------------------------
# tools
# -----------------------------------------------------------------------------


Platform = Literal["leaflet", "pckt", "offprint", "greengale", "other"]


def _extract_results(data: Any) -> list[dict[str, Any]]:
    """extract results array from API response (handles both v1 and v2 formats)."""
    if isinstance(data, dict) and "results" in data:
        return data["results"]
    if isinstance(data, list):
        return data
    return []


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

    params: dict[str, Any] = {"format": "v2", "limit": str(limit)}
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
        data = response.json()

    results = _extract_results(data)
    return [SearchResult(**r) for r in results[:limit]]


@mcp.tool
async def search_semantic(
    query: str,
    platform: Platform | None = None,
    limit: int = 5,
) -> list[SearchResult]:
    """semantic search using vector embeddings.

    finds documents by meaning rather than exact keyword match.
    good for natural language queries like "essays about loneliness"
    or oblique descriptions like "guy from south africa with lots of kids".

    args:
        query: natural language query
        platform: filter by platform (leaflet, pckt, offprint, greengale, other)
        limit: max results (default 5, max 40)

    returns:
        list of results ranked by semantic similarity
    """
    params: dict[str, Any] = {"q": query, "mode": "semantic", "format": "v2", "limit": str(limit)}
    if platform:
        params["platform"] = platform

    async with get_http_client() as client:
        response = await client.get("/search", params=params)
        response.raise_for_status()
        data = response.json()

    if isinstance(data, dict) and "error" in data:
        return []

    results = _extract_results(data)
    return [SearchResult(**r) for r in results[:limit]]


@mcp.tool
async def search_hybrid(
    query: str,
    platform: Platform | None = None,
    limit: int = 5,
) -> list[SearchResult]:
    """hybrid search combining keyword and semantic results.

    runs both keyword (exact match) and semantic (meaning-based) search,
    then merges results using Reciprocal Rank Fusion. documents found by
    both methods rank highest. results include a `source` field indicating
    how each result was found: "keyword", "semantic", or "keyword+semantic".

    args:
        query: search query
        platform: filter by platform (leaflet, pckt, offprint, greengale, other)
        limit: max results (default 5, max 40)

    returns:
        list of results with source annotations, ranked by combined relevance
    """
    params: dict[str, Any] = {"q": query, "mode": "hybrid", "format": "v2", "limit": str(limit)}
    if platform:
        params["platform"] = platform

    async with get_http_client() as client:
        response = await client.get("/search", params=params)
        response.raise_for_status()
        data = response.json()

    if isinstance(data, dict) and "error" in data:
        return []

    results = _extract_results(data)
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
    # pub.leaflet.document: pages[].blocks[].block.plaintext
    # site.standard.document: content.pages[].blocks[].block.plaintext
    content_parts = []

    # handle both formats: top-level pages (pub.leaflet.document)
    # or nested under content (site.standard.document)
    pages = value.get("pages", [])
    if not pages:
        content_obj = value.get("content", {})
        if isinstance(content_obj, dict):
            pages = content_obj.get("pages", [])

    for page in pages:
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

    uses vector similarity to find semantically related documents.
    great for discovering related content after finding
    an interesting document.

    args:
        uri: the AT-URI of the document to find similar content for
        limit: max similar documents to return (default 5)

    returns:
        list of similar documents with uri, title, and metadata
    """
    async with get_http_client() as client:
        response = await client.get("/similar", params={"uri": uri, "format": "v2"})
        response.raise_for_status()
        data = response.json()

    results = _extract_results(data)
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
        response = await client.get("/tags", params={"format": "v2"})
        response.raise_for_status()
        data = response.json()

    results = _extract_results(data)
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
        response = await client.get("/popular", params={"format": "v2"})
        response.raise_for_status()
        data = response.json()

    results = _extract_results(data)
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
