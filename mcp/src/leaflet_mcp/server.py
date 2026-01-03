"""Leaflet MCP server implementation using fastmcp."""

from __future__ import annotations

from typing import Any

from fastmcp import FastMCP

from leaflet_mcp._types import Document, PopularSearch, SearchResult, Stats, Tag
from leaflet_mcp.client import get_http_client

mcp = FastMCP("leaflet")


# -----------------------------------------------------------------------------
# prompts
# -----------------------------------------------------------------------------


@mcp.prompt("usage_guide")
def usage_guide() -> str:
    """instructions for using leaflet MCP tools."""
    return """\
# Leaflet MCP server usage guide

Leaflet is a decentralized publishing platform on ATProto (the protocol behind Bluesky).
This MCP server provides search and discovery tools for Leaflet publications.

## core tools

- `search(query, tag)` - search documents and publications by text or tag
- `get_document(uri)` - get the full content of a document by its AT-URI
- `find_similar(uri)` - find documents similar to a given document
- `get_tags()` - list all available tags with document counts
- `get_stats()` - get index statistics (document/publication counts)
- `get_popular()` - see popular search queries

## workflow for research

1. use `search("your topic")` to find relevant documents
2. use `get_document(uri)` to retrieve full content of interesting results
3. use `find_similar(uri)` to discover related content

## result types

search returns three types of results:
- **publication**: a collection of articles (like a blog or magazine)
- **article**: a document that belongs to a publication
- **looseleaf**: a standalone document not part of a publication

## AT-URIs

documents are identified by AT-URIs like:
  `at://did:plc:abc123/pub.leaflet.document/xyz789`

you can also browse documents on the web at leaflet.pub
"""


@mcp.prompt("search_tips")
def search_tips() -> str:
    """tips for effective searching."""
    return """\
# Leaflet search tips

## text search
- searches both document titles and content
- uses FTS5 full-text search with prefix matching
- the last word gets prefix matching: "cat dog" matches "cat dogs"

## tag filtering
- combine text search with tag filter: `search("python", tag="programming")`
- use `get_tags()` to discover available tags
- tags are only applied to documents, not publications

## finding related content
- after finding an interesting document, use `find_similar(uri)`
- similarity is based on semantic embeddings (voyage-3-lite)
- great for exploring related topics

## browsing by popularity
- use `get_popular()` to see what others are searching for
- can inspire new research directions
"""


# -----------------------------------------------------------------------------
# tools
# -----------------------------------------------------------------------------


@mcp.tool
async def search(
    query: str = "",
    tag: str | None = None,
    limit: int = 5,
) -> list[SearchResult]:
    """search leaflet documents and publications.

    searches the full text of documents (titles and content) and publications.
    results include a snippet showing where the match was found.

    args:
        query: search query (searches titles and content)
        tag: optional tag to filter by (only applies to documents)
        limit: max results to return (default 5, max 40)

    returns:
        list of search results with uri, title, snippet, and metadata
    """
    if not query and not tag:
        return []

    params: dict[str, Any] = {}
    if query:
        params["q"] = query
    if tag:
        params["tag"] = tag

    async with get_http_client() as client:
        response = await client.get("/search", params=params)
        response.raise_for_status()
        results = response.json()

    # apply client-side limit since API returns up to 40
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
    """get leaflet index statistics.

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

    see what others are searching for on leaflet.
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


@mcp.resource("leaflet://stats")
async def stats_resource() -> str:
    """current leaflet index statistics."""
    stats = await get_stats()
    return f"Leaflet index: {stats.documents} documents, {stats.publications} publications"


# -----------------------------------------------------------------------------
# entrypoint
# -----------------------------------------------------------------------------


def main() -> None:
    """run the MCP server."""
    mcp.run()


if __name__ == "__main__":
    main()
