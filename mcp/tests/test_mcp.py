"""tests for pub-search MCP server."""

import pytest
from mcp.types import TextContent

from fastmcp.client import Client
from fastmcp.client.transports import FastMCPTransport

from pub_search._types import Document, EndpointTiming, PopularSearch, SearchResult, Stats, Tag
from pub_search.server import mcp


class TestTypes:
    """tests for type definitions."""

    def test_search_result(self):
        """SearchResult can be constructed."""
        r = SearchResult(
            type="article",
            uri="at://did:plc:abc/pub.leaflet.document/123",
            did="did:plc:abc",
            title="test article",
            snippet="this is a test...",
            createdAt="2025-01-01T00:00:00Z",
            rkey="123",
            basePath="gyst.leaflet.pub",
            platform="leaflet",
            url="https://gyst.leaflet.pub/123",
        )
        assert r.type == "article"
        assert r.uri == "at://did:plc:abc/pub.leaflet.document/123"
        assert r.title == "test article"
        assert r.platform == "leaflet"
        assert r.url == "https://gyst.leaflet.pub/123"

    def test_search_result_looseleaf(self):
        """SearchResult supports looseleaf type."""
        r = SearchResult(
            type="looseleaf",
            uri="at://did:plc:abc/pub.leaflet.document/456",
            did="did:plc:abc",
            title="standalone doc",
            snippet="no publication...",
            rkey="456",
        )
        assert r.type == "looseleaf"
        assert r.basePath == ""

    def test_search_result_publication(self):
        """SearchResult supports publication type."""
        r = SearchResult(
            type="publication",
            uri="at://did:plc:abc/pub.leaflet.publication/789",
            did="did:plc:abc",
            title="my blog",
            snippet="a personal blog...",
            rkey="789",
            basePath="/blog",
        )
        assert r.type == "publication"

    def test_tag(self):
        """Tag can be constructed."""
        t = Tag(tag="python", count=42)
        assert t.tag == "python"
        assert t.count == 42

    def test_popular_search(self):
        """PopularSearch can be constructed."""
        p = PopularSearch(query="rust async", count=100)
        assert p.query == "rust async"
        assert p.count == 100

    def test_stats_minimal(self):
        """Stats can be constructed with just documents/publications."""
        s = Stats(documents=1000, publications=50)
        assert s.documents == 1000
        assert s.publications == 50
        assert s.embeddings == 0
        assert s.timing == {}

    def test_stats_full(self):
        """Stats can be constructed with all fields from API."""
        s = Stats(
            documents=6527,
            publications=2335,
            embeddings=6527,
            searches=5321,
            errors=0,
            started_at=1767333441,
            cache_hits=978,
            cache_misses=627,
            timing={
                "search_keyword": EndpointTiming(
                    count=320, avg_ms=140.1, p50_ms=7.7, p95_ms=616.2, p99_ms=1090.1, max_ms=7294.9
                ),
            },
        )
        assert s.embeddings == 6527
        assert s.cache_hits == 978
        assert s.timing["search_keyword"].p50_ms == 7.7

    def test_document(self):
        """Document can be constructed with full content."""
        d = Document(
            uri="at://did:plc:abc/pub.leaflet.document/123",
            title="full article",
            content="this is the full content of the article...",
            createdAt="2025-01-01T00:00:00Z",
            tags=["python", "tutorial"],
            publicationUri="at://did:plc:abc/pub.leaflet.publication/blog",
        )
        assert d.uri == "at://did:plc:abc/pub.leaflet.document/123"
        assert "full content" in d.content
        assert "python" in d.tags


class TestMcpServerImports:
    """tests for MCP server module imports."""

    def test_mcp_server_imports(self):
        """mcp server can be imported without errors."""
        from pub_search import mcp

        assert mcp.name == "pub-search"

    def test_exports(self):
        """all expected exports are available."""
        from pub_search import main, mcp

        assert mcp is not None
        assert main is not None
        assert callable(main)


class TestMcpServerRegistration:
    """tests for MCP server tool/prompt/resource registration."""

    @pytest.fixture
    def client(self):
        """Create a FastMCP client for testing."""
        return Client(transport=FastMCPTransport(mcp))

    async def test_list_tools(self, client):
        """verify all expected tools are registered."""
        async with client:
            tools = await client.list_tools()

        tool_names = {t.name for t in tools}
        expected = {"search", "get_document", "find_similar", "get_tags", "get_stats", "get_popular"}
        assert expected == tool_names

    async def test_list_prompts(self, client):
        """verify prompts are registered."""
        async with client:
            prompts = await client.list_prompts()

        prompt_names = {p.name for p in prompts}
        assert "usage_guide" in prompt_names
        assert "search_tips" in prompt_names

    async def test_list_resources(self, client):
        """verify resources are registered."""
        async with client:
            resources = await client.list_resources()

        resource_uris = {str(r.uri) for r in resources}
        assert "pub-search://stats" in resource_uris

    async def test_usage_guide_prompt_content(self, client):
        """usage_guide prompt returns helpful content."""
        async with client:
            result = await client.get_prompt("usage_guide")

        assert len(result.messages) > 0
        content = result.messages[0].content
        assert isinstance(content, TextContent)
        assert "pub-search" in content.text
        assert "search" in content.text

    async def test_search_tips_prompt_content(self, client):
        """search_tips prompt returns helpful content."""
        async with client:
            result = await client.get_prompt("search_tips")

        assert len(result.messages) > 0
        content = result.messages[0].content
        assert isinstance(content, TextContent)
        assert "search" in content.text.lower()
