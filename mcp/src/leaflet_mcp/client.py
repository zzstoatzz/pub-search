"""HTTP client for Leaflet search API."""

import os
from contextlib import asynccontextmanager
from typing import AsyncIterator

import httpx

# configurable via env var, defaults to production
LEAFLET_API_URL = os.getenv("LEAFLET_API_URL", "https://leaflet-backend.fly.dev")


@asynccontextmanager
async def get_http_client() -> AsyncIterator[httpx.AsyncClient]:
    """Get an async HTTP client for Leaflet API requests."""
    async with httpx.AsyncClient(
        base_url=LEAFLET_API_URL,
        timeout=30.0,
        headers={"Accept": "application/json"},
    ) as client:
        yield client
