#!/usr/bin/env python3
"""diagnose search API latency"""

import time
import httpx

BASE_URL = "https://leaflet-search-backend.fly.dev"

def timed_request(url: str, name: str) -> float:
    start = time.perf_counter()
    resp = httpx.get(url, timeout=30)
    elapsed = time.perf_counter() - start
    print(f"{name}: {elapsed:.3f}s (status={resp.status_code})")
    return elapsed

def main():
    print("=== latency diagnosis ===\n")

    # warmup
    print("1. warmup request (health):")
    timed_request(f"{BASE_URL}/health", "   health")

    print("\n2. first search (cold db?):")
    t1 = timed_request(f"{BASE_URL}/search?q=atproto", "   search")

    print("\n3. rapid follow-up searches:")
    times = []
    for i in range(5):
        t = timed_request(f"{BASE_URL}/search?q=blog", f"   search {i+1}")
        times.append(t)

    print(f"\n4. stats (single query):")
    timed_request(f"{BASE_URL}/stats", "   stats")

    print(f"\n5. dashboard (batched queries):")
    timed_request(f"{BASE_URL}/api/dashboard", "   dashboard")

    print("\n=== summary ===")
    print(f"first search: {t1:.3f}s")
    print(f"follow-up avg: {sum(times)/len(times):.3f}s")
    print(f"follow-up min: {min(times):.3f}s")
    print(f"follow-up max: {max(times):.3f}s")

    if t1 > 5:
        print("\n⚠️  first request very slow - likely turso cold start")
    if sum(times)/len(times) > 1:
        print("⚠️  follow-up requests still slow - query optimization needed")
        print("   suggestion: batch the 3 search queries into 1 http request")

if __name__ == "__main__":
    main()
