"""Type definitions for Leaflet MCP responses."""

from typing import Literal

from pydantic import BaseModel


class SearchResult(BaseModel):
    """A search result from the Leaflet API."""

    type: Literal["article", "looseleaf", "publication"]
    uri: str
    did: str
    title: str
    snippet: str
    createdAt: str = ""
    rkey: str
    basePath: str = ""
    platform: Literal["leaflet", "pckt", "offprint", "greengale", "whitewind", "other"] = "leaflet"
    path: str = ""
    source: str = ""
    score: float = 0.0
    publicationName: str = ""
    url: str = ""


class Tag(BaseModel):
    """A tag with document count."""

    tag: str
    count: int


class PopularSearch(BaseModel):
    """A popular search query with count."""

    query: str
    count: int


class EndpointTiming(BaseModel):
    """Timing stats for a single endpoint."""

    count: int = 0
    avg_ms: float = 0.0
    p50_ms: float = 0.0
    p95_ms: float = 0.0
    p99_ms: float = 0.0
    max_ms: float = 0.0


class Stats(BaseModel):
    """Index statistics."""

    documents: int
    publications: int
    embeddings: int = 0
    searches: int = 0
    errors: int = 0
    started_at: int = 0
    cache_hits: int = 0
    cache_misses: int = 0
    timing: dict[str, EndpointTiming] = {}


class Document(BaseModel):
    """Full document content from ATProto."""

    uri: str
    title: str
    content: str
    createdAt: str = ""
    tags: list[str] = []
    publicationUri: str = ""
