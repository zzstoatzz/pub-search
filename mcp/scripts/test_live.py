#!/usr/bin/env python3
"""Test the pub-search MCP server."""

import asyncio
import sys

from fastmcp import Client
from fastmcp.client.transports import FastMCPTransport

from pub_search.server import mcp


async def main():
    # use local transport for testing, or live URL if --live flag
    if "--live" in sys.argv:
        print("testing against live Horizon server...")
        client = Client("https://pub-search-by-zzstoatzz.fastmcp.app/mcp")
    else:
        print("testing locally with FastMCPTransport...")
        client = Client(transport=FastMCPTransport(mcp))

    async with client:
        # list tools
        print("=== tools ===")
        tools = await client.list_tools()
        for t in tools:
            print(f"  {t.name}")

        # test search with new platform filter
        print("\n=== search(query='zig', platform='leaflet', limit=3) ===")
        result = await client.call_tool(
            "search", {"query": "zig", "platform": "leaflet", "limit": 3}
        )
        for item in result.content:
            print(f"  {item.text[:200]}...")

        # test search with since filter
        print("\n=== search(query='python', since='2025-01-01', limit=2) ===")
        result = await client.call_tool(
            "search", {"query": "python", "since": "2025-01-01", "limit": 2}
        )
        for item in result.content:
            print(f"  {item.text[:200]}...")

        # test get_tags
        print("\n=== get_tags() ===")
        result = await client.call_tool("get_tags", {})
        for item in result.content:
            print(f"  {item.text[:150]}...")

        # test get_stats
        print("\n=== get_stats() ===")
        result = await client.call_tool("get_stats", {})
        for item in result.content:
            print(f"  {item.text}")

        # test get_popular
        print("\n=== get_popular(limit=3) ===")
        result = await client.call_tool("get_popular", {"limit": 3})
        for item in result.content:
            print(f"  {item.text[:100]}...")

        print("\n=== all tests passed ===")


if __name__ == "__main__":
    asyncio.run(main())
