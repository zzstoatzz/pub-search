#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx", "rich", "plotext", "typer"]
# ///
"""pub-search terminal dashboard

usage:
    uv run scripts/dashboard.py           # default view
    uv run scripts/dashboard.py --days 14 # longer timeline
"""

import httpx
import plotext as plt
import typer
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

API_BASE = "https://leaflet-search-backend.fly.dev"
console = Console()
app = typer.Typer(add_completion=False)


def fetch_stats() -> dict:
    """fetch /stats endpoint"""
    resp = httpx.get(f"{API_BASE}/stats", timeout=30)
    resp.raise_for_status()
    return resp.json()


def fetch_dashboard() -> dict:
    """fetch /api/dashboard endpoint"""
    resp = httpx.get(f"{API_BASE}/api/dashboard", timeout=30)
    resp.raise_for_status()
    return resp.json()


def display_overview(stats: dict) -> None:
    """show document/publication counts"""
    table = Table(show_header=False, box=None, padding=(0, 2), expand=True)
    table.add_column(style="dim")
    table.add_column(style="bold green", justify="right")

    table.add_row("documents", f"{stats['documents']:,}")
    table.add_row("publications", f"{stats['publications']:,}")
    table.add_row("embeddings", f"{stats['embeddings']:,}")

    embed_pct = (stats['embeddings'] / stats['documents'] * 100) if stats['documents'] > 0 else 0
    table.add_row("embedded", f"{embed_pct:.0f}%")

    console.print(Panel(table, title="[bold]index[/]", border_style="blue", expand=False))


def display_usage(stats: dict) -> None:
    """show usage and similarity cache stats"""
    hits = stats.get('cache_hits', 0)
    misses = stats.get('cache_misses', 0)
    total = hits + misses
    hit_rate = (hits / total * 100) if total > 0 else 0

    table = Table(show_header=False, box=None, padding=(0, 2), expand=True)
    table.add_column(style="dim")
    table.add_column(style="bold cyan", justify="right")

    table.add_row("searches", f"{stats.get('searches', 0):,}")
    table.add_row("errors", f"{stats.get('errors', 0):,}")
    table.add_row("similar cache hit", f"{hit_rate:.0f}% ({hits}/{total})")

    console.print(Panel(table, title="[bold]usage[/]", border_style="cyan", expand=False))


def display_latency(stats: dict) -> None:
    """show latency percentiles"""
    timing = stats.get('timing', {})
    if not timing:
        return

    table = Table(box=None, padding=(0, 1), expand=True)
    table.add_column("endpoint", style="dim")
    table.add_column("p50", justify="right", style="green")
    table.add_column("p95", justify="right", style="yellow")
    table.add_column("p99", justify="right", style="red")
    table.add_column("count", justify="right", style="dim")

    for endpoint in ['search', 'similar', 'tags', 'popular']:
        if endpoint in timing:
            t = timing[endpoint]
            table.add_row(
                endpoint,
                f"{t['p50_ms']:.0f}ms",
                f"{t['p95_ms']:.0f}ms",
                f"{t['p99_ms']:.0f}ms",
                f"{t['count']:,}",
            )

    console.print(Panel(table, title="[bold]latency[/]", border_style="magenta", expand=False))


def display_timeline(dashboard: dict, days: int) -> None:
    """show indexing activity chart"""
    timeline = dashboard.get('timeline', [])[:days]
    if not timeline:
        return

    timeline = list(reversed(timeline))  # oldest first
    dates = [d['date'][-5:] for d in timeline]  # MM-DD
    counts = [d['count'] for d in timeline]

    plt.clear_figure()
    plt.theme("dark")
    plt.title("documents indexed per day")
    plt.bar(dates, counts, color="cyan")
    plt.plotsize(70, 12)
    plt.show()
    print()


def display_latency_chart(stats: dict) -> None:
    """bar chart of p50 latencies by endpoint"""
    timing = stats.get('timing', {})
    if not timing:
        return

    endpoints = []
    p50s = []
    for endpoint in ['search', 'similar', 'tags', 'popular']:
        if endpoint in timing:
            endpoints.append(endpoint)
            p50s.append(timing[endpoint]['p50_ms'])

    plt.clear_figure()
    plt.theme("dark")
    plt.title("p50 latency by endpoint (ms)")
    plt.bar(endpoints, p50s, color="cyan")
    plt.plotsize(50, 10)
    plt.show()
    print()


@app.command()
def main(
    days: int = typer.Option(7, "-d", "--days", help="days of timeline to show"),
) -> None:
    """pub-search terminal dashboard"""
    console.print("\n[bold cyan]pub-search[/] dashboard\n")

    try:
        stats = fetch_stats()
        dashboard = fetch_dashboard()
    except httpx.HTTPError as e:
        console.print(f"[red]error fetching data:[/] {e}")
        raise typer.Exit(1)

    display_overview(stats)
    display_usage(stats)
    display_latency(stats)
    print()
    display_timeline(dashboard, days)
    display_latency_chart(stats)


if __name__ == "__main__":
    app()
