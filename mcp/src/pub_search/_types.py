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
    platform: Literal["leaflet", "pckt", "offprint", "greengale", "other"] = "leaflet"
    path: str = ""
    source: str = ""
    score: float = 0.0

    @computed_field
    @property
    def url(self) -> str:
        """web URL for this document."""
        if self.type == "publication" and self.basePath:
            return f"https://{self.basePath}"
        if self.platform == "leaflet" and self.basePath and self.rkey:
            return f"https://{self.basePath}/{self.rkey}"
        if self.basePath and self.path:
            sep = "" if self.path.startswith("/") else "/"
            return f"https://{self.basePath}{sep}{self.path}"
        if self.platform == "leaflet" and self.did and self.rkey:
            return f"https://leaflet.pub/p/{self.did}/{self.rkey}"
        if self.uri:
            return f"https://pdsls.dev/{self.uri}"
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
