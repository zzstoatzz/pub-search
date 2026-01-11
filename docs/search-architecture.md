# search architecture

current state, rationale, and future options.

## current: SQLite FTS5

we use SQLite's built-in full-text search (FTS5) via Turso.

### why FTS5 works for now

- **scale**: ~3500 documents. FTS5 handles this trivially.
- **latency**: 10-50ms for search queries. fine for our use case.
- **cost**: $0. included with Turso free tier.
- **ops**: zero. no separate service to run.
- **simplicity**: one database for everything (docs, FTS, vectors, cache).

### how it works

```
user query: "crypto-casino"
     ↓
buildFtsQuery(): "crypto OR casino*"
     ↓
FTS5 MATCH query with BM25 ranking
     ↓
results with snippet()
```

key decisions:
- **OR between terms** for better recall (deliberate, see commit 35ad4b5)
- **prefix match on last word** for type-ahead feel
- **unicode61 tokenizer** splits on non-alphanumeric (we match this in buildFtsQuery)

### what's coupled to FTS5

all in `backend/src/search.zig`:

| component | FTS5-specific |
|-----------|---------------|
| 10 query definitions | `MATCH`, `snippet()`, `ORDER BY rank` |
| `buildFtsQuery()` | constructs FTS5 syntax |
| schema | `documents_fts`, `publications_fts` virtual tables |

### what's already decoupled

- result types (`SearchResultJson`, `Doc`, `Pub`)
- similarity search (uses `vector_distance_cos`, not FTS5)
- caching logic
- HTTP layer (server.zig just calls `search()`)

### known limitations

- **no typo tolerance**: "leafet" won't find "leaflet"
- **no relevance tuning**: can't boost title vs content
- **single writer**: SQLite write lock
- **no horizontal scaling**: single database

these aren't problems at current scale.

## future: if we need to scale

### when to consider switching

- search latency consistently >100ms
- write contention from indexing
- need typo tolerance or better relevance
- millions of documents

### recommended: Elasticsearch

Elasticsearch is the battle-tested choice for production search:

- proven at massive scale (Wikipedia, GitHub, Stack Overflow)
- rich query DSL, analyzers, aggregations
- typo tolerance via fuzzy matching
- horizontal scaling built-in
- extensive tooling and community

trade-offs:
- operational complexity (JVM, cluster management)
- resource hungry (~2GB+ RAM minimum)
- cost: $50-500/month depending on scale

### alternatives considered

**Meilisearch/Typesense**: simpler, lighter, great defaults. good for straightforward search but less proven at scale. would work fine for this use case but Elasticsearch has more headroom.

**Algolia**: fully managed, excellent but expensive. makes sense if you want zero ops.

**PostgreSQL full-text**: if already on Postgres. not as good as FTS5 or Elasticsearch but one less system.

### migration path

1. keep Turso as source of truth
2. add Elasticsearch as search index
3. sync documents to ES on write (async)
4. point `/search` at Elasticsearch
5. keep `/similar` on Turso (vector search)

the `search()` function would change from SQL queries to ES client calls. result types stay the same. HTTP layer unchanged.

estimated effort: 1-2 days to swap search backend.

### vector search scaling

similarity search currently uses brute-force `vector_distance_cos` with caching. at scale:

- **Elasticsearch**: has vector search (dense_vector + kNN)
- **dedicated vector DB**: Qdrant, Pinecone, Weaviate
- **pgvector**: if on Postgres

could consolidate text + vector in Elasticsearch, or keep them separate.

## summary

| scale | recommendation |
|-------|----------------|
| <10k docs | keep FTS5 (current) |
| 10k-100k docs | still probably fine, monitor latency |
| 100k+ docs | consider Elasticsearch |
| millions + sub-ms latency | Elasticsearch cluster + caching layer |

we're in the "keep FTS5" zone. the code is structured to swap later if needed.
