# API reference

base URL: `https://leaflet-search-backend.fly.dev`

## endpoints

### search

```
GET /search?q=<query>&tag=<tag>&platform=<platform>&since=<date>
```

full-text search across documents and publications.

**parameters:**
| param | type | required | description |
|-------|------|----------|-------------|
| `q` | string | no* | search query (titles and content) |
| `tag` | string | no | filter by tag (documents only) |
| `platform` | string | no | filter by platform: `leaflet`, `pckt`, `offprint`, `greengale`, `other` |
| `since` | string | no | ISO date, filter to documents created after |

*at least one of `q` or `tag` required

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
    "path": "/001"
  }
]
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

find semantically similar documents using vector similarity (voyage-3-lite embeddings).

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

### platforms

```
GET /platforms
```

document counts by platform.

**response:**
```json
[
  {"platform": "leaflet", "count": 2500},
  {"platform": "pckt", "count": 800},
  {"platform": "greengale", "count": 150},
  {"platform": "offprint", "count": 50},
  {"platform": "other", "count": 100}
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
  "documents": 3500,
  "publications": 120,
  "embeddings": 3200,
  "searches": 5000,
  "errors": 5,
  "cache_hits": 1200,
  "cache_misses": 800,
  "timing": {
    "search": {"count": 1000, "avg_ms": 25, "p50_ms": 20, "p95_ms": 50, "p99_ms": 80, "max_ms": 150},
    "similar": {"count": 200, "avg_ms": 150, "p50_ms": 140, "p95_ms": 200, "p99_ms": 250, "max_ms": 300},
    "tags": {"count": 500, "avg_ms": 5, "p50_ms": 4, "p95_ms": 10, "p99_ms": 15, "max_ms": 25},
    "popular": {"count": 300, "avg_ms": 3, "p50_ms": 2, "p95_ms": 5, "p99_ms": 8, "max_ms": 12}
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

rich dashboard data for analytics UI.

**response:**
```json
{
  "startedAt": 1705000000,
  "searches": 5000,
  "publications": 120,
  "documents": 3500,
  "platforms": [{"platform": "leaflet", "count": 2500}],
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

documents can be accessed on the web via their `basePath` and `rkey`:
- articles: `https://{basePath}/{rkey}` or `https://{basePath}{path}` if path is set
- publications: `https://{basePath}`

examples:
- `https://gyst.leaflet.pub/3ldasifz7bs2l`
- `https://greengale.app/3fz.org/001`
