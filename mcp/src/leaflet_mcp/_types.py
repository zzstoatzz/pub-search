"""Type definitions for Leaflet MCP responses."""

from typing import Literal

from pydantic import BaseModel, computed_field


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

    @computed_field
    @property
    def url(self) -> str:
        """web URL for this document."""
        if self.basePath:
            return f"https://{self.basePath}/{self.rkey}"
        return ""


class Tag(BaseModel):
    """A tag with document count."""

    tag: str
    count: int


class PopularSearch(BaseModel):
    """A popular search query with count."""

    query: str
    count: int


class Stats(BaseModel):
    """Leaflet index statistics."""

    documents: int
    publications: int


class Document(BaseModel):
    """Full document content from ATProto."""

    uri: str
    title: str
    content: str
    createdAt: str = ""
    tags: list[str] = []
    publicationUri: str = ""
