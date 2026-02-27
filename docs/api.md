# API reference

base URL: `https://leaflet-search-backend.fly.dev`

## endpoints

### search

```
GET /search?q=<query>&tag=<tag>&platform=<platform>&since=<date>&mode=<mode>
```

full-text search across documents and publications.

**parameters:**
| param | type | required | description |
|-------|------|----------|-------------|
| `q` | string | no* | search query (titles and content) |
| `tag` | string | no | filter by tag (documents only) |
| `platform` | string | no | filter by platform: `leaflet`, `pckt`, `offprint`, `greengale`, `whitewind`, `other` |
| `since` | string | no | ISO date, filter to documents created after |
| `mode` | string | no | `keyword` (default), `semantic`, or `hybrid`. semantic uses voyage-4-lite embeddings + turbopuffer ANN. hybrid merges keyword + semantic via reciprocal rank fusion. |
| `format` | string | no | `v2` wraps response in `{"results": [...], "total": N, "hasMore": bool}` |
| `limit` | int | no | max results to return (default 20) |
| `offset` | int | no | pagination offset |

*at least one of `q` or `tag` required

**filter behavior by mode:**
- **keyword**: respects all filters (`tag`, `platform`, `since`)
- **semantic**: respects `platform` only. ignores `tag` and `since`.
- **hybrid**: keyword half respects all filters, semantic half respects `platform` only. results merged via RRF.

**response:**
```json
[
  {
    "type": "article|looseleaf|publication",
    "uri": "at://did:plc:.../collection/rkey",
    "did": "did:plc:...",
    "title": "document title",
    "snippet": "...matched text...",
    "createdAt": "2025-01-15T...",
    "rkey": "abc123",
    "basePath": "gyst.leaflet.pub",
    "platform": "leaflet",
    "path": "/001",
    "coverImage": "",
    "handle": "@user.bsky.social"
  }
]
```

with `format=v2`:
```json
{
  "results": [ /* same as above */ ],
  "total": 89,
  "hasMore": false
}
```

hybrid mode adds `source` and `score` fields:
```json
{
  "source": "keyword+semantic",
  "score": 0.85
}
```

**result types:**
- `article`: document in a publication
- `looseleaf`: standalone document (no publication)
- `publication`: the publication itself (only returned for text queries, not tag/platform filters)

**ranking:** hybrid BM25 + recency. text relevance primary, recent docs boosted (~1 point per 30 days).

### similar

```
GET /similar?uri=<at-uri>
```

find semantically similar documents using vector similarity (voyage-4-lite embeddings + turbopuffer ANN).

**parameters:**
| param | type | required | description |
|-------|------|----------|-------------|
| `uri` | string | yes | AT-URI of source document |

**response:** same format as search (array of results)

### tags

```
GET /tags
```

list all tags with document counts, sorted by popularity.

**response:**
```json
[
  {"tag": "programming", "count": 42},
  {"tag": "rust", "count": 15}
]
```

### popular

```
GET /popular
```

popular search queries.

**response:**
```json
[
  {"query": "rust async", "count": 12},
  {"query": "leaflet", "count": 8}
]
```

### stats

```
GET /stats
```

index statistics and request timing.

**response:**
```json
{
  "documents": 11445,
  "publications": 2603,
  "embeddings": 10900,
  "searches": 5000,
  "errors": 5,
  "cache_hits": 1200,
  "cache_misses": 800,
  "timing": {
    "search_keyword": {"count": 1000, "avg_ms": 25, "p50_ms": 20, "p95_ms": 50, "p99_ms": 80, "max_ms": 150},
    "search_semantic": {"count": 100, "avg_ms": 350, "p50_ms": 340, ...},
    "search_hybrid": {"count": 50, "avg_ms": 380, ...},
    "similar": {"count": 200, "avg_ms": 150, ...},
    "tags": {"count": 500, "avg_ms": 5, ...},
    "popular": {"count": 300, "avg_ms": 3, ...}
  }
}
```

### activity

```
GET /activity
```

hourly activity counts (last 24 hours).

**response:**
```json
[12, 8, 5, 3, 2, 1, 0, 0, 1, 5, 15, 25, 30, 28, 22, 18, 20, 25, 30, 35, 28, 20, 15, 10]
```

### dashboard

```
GET /api/dashboard
```

rich dashboard data for analytics UI. includes platform counts (no separate `/platforms` endpoint).

**response:**
```json
{
  "startedAt": 1705000000,
  "searches": 5000,
  "publications": 2603,
  "documents": 11445,
  "platforms": [{"platform": "leaflet", "count": 5399}],
  "tags": [{"tag": "programming", "count": 42}],
  "timeline": [{"date": "2025-01-15", "count": 25}],
  "topPubs": [{"name": "gyst", "basePath": "gyst.leaflet.pub", "count": 150}],
  "timing": {...}
}
```

### health

```
GET /health
```

**response:**
```json
{"status": "ok"}
```

## building URLs

documents can be accessed on the web via their `basePath` and platform-specific patterns:

| platform | URL pattern | example |
|----------|-------------|---------|
| leaflet | `https://{basePath}/{rkey}` | `https://gyst.leaflet.pub/3ldasifz7bs2l` |
| pckt | `https://{basePath}{path}` | `https://devlog.pckt.blog/some-slug` |
| offprint | `https://{basePath}{path}` | `https://dalisay.offprint.app/a/3me5ucj7vxf23-title-slug` |
| greengale | `https://{basePath}{path}` | `https://3fz.greengale.app/001` |
| whitewind | `https://whtwnd.com/{did}/{rkey}` | `https://whtwnd.com/did:plc:.../3abc123` |
| publications | `https://{basePath}` | `https://gyst.leaflet.pub` |
