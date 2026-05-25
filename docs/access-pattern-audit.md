# access-pattern audit (may 2026)

companion to [performance-saga.md](performance-saga.md). that one was about
*latency* — multi-second stalls in the request hot path. this one is about
*cost* — a slow burn of unnecessary turso row reads from background
workers and cache refreshes, surfaced by a row-read spike on the turso
dashboard.

## what we noticed

turso's row-read graph spiked. `turso db inspect leaf --queries` (a
**per-query** rows-read breakdown — far more useful than the dashboard
graphs for cost forensics) showed three culprits accounting for the
majority of period-to-date reads:

| query | role | PTD rows read |
|-------|------|---------------|
| `SELECT ... FROM documents WHERE verified_at IS NULL OR verified_at < ? ORDER BY ... LIMIT 50` | reconciler batch | **51.7M** |
| `SELECT ... FROM documents d JOIN recommends r ...` (×15 cache slots / 5min) | leaderboard cache | **63.9M** |
| `SELECT ... FROM documents WHERE embedded_at IS NULL LIMIT 50` | embedder batch | **7.2M** |

each of these is *bounded by `LIMIT`* — they look cheap. but each ran on
a periodic schedule (every 30 min / 5 min / continuous), and each
required scanning the full `documents` table (~18k rows) every time
because the columns being filtered weren't indexed.

## phase 0: indexes (migration 015)

`migration 015_index_documents_verified_at_embedded_at` adds:

```sql
CREATE INDEX IF NOT EXISTS idx_documents_verified_at ON documents(verified_at);
CREATE INDEX IF NOT EXISTS idx_documents_embedded_at ON documents(embedded_at);
```

reconciler query plan: `SCAN documents` → `SCAN documents USING INDEX
idx_documents_verified_at` (no more TEMP B-TREE sort either — the index
order matches the `ORDER BY`). embedder query plan: `SCAN documents` →
`SEARCH documents USING INDEX idx_documents_embedded_at`. per-cycle reads
drop from ~18k → ~LIMIT.

local SQLite replica intentionally skipped — neither column is filtered
on the search path, so the indexes only matter on turso.

## phase 1: pre-aggregate the leaderboard query

the leaderboard cache (`/recommended` top/trending + `/curators`) ran a
`documents JOIN recommends GROUP BY d.uri` every 5 minutes across 15
cache slots (5 windows × 2 sorts + curators). naive plan:

```
SCAN d USING INDEX sqlite_autoindex_documents_1       ← all 17.9k docs
SEARCH r USING INDEX idx_recommends_document_uri (...) ← per-doc probe
USE TEMP B-TREE FOR count(DISTINCT) × 2
USE TEMP B-TREE FOR ORDER BY
```

`recommends` is small (~2.6k rows) and only ~880 documents have *any*
recommends. so the SCAN over 18k docs is mostly wasted — 95% of the rows
contribute nothing to the result.

the fix in `backend/src/server/recommended.zig` is to pre-aggregate
`recommends` in a subquery-in-`FROM`, then look up the matched documents
by PK:

```sql
SELECT d.uri, d.title, agg.recommend_count, agg.total_count
FROM (
  SELECT document_uri,
    COUNT(DISTINCT CASE WHEN ... THEN did END) AS recommend_count,
    COUNT(DISTINCT did) AS total_count
  FROM recommends GROUP BY document_uri HAVING recommend_count > 0
) agg
JOIN documents d ON d.uri = agg.document_uri
LEFT JOIN publications p ON d.publication_uri = p.uri
ORDER BY agg.recommend_count DESC, d.created_at DESC
LIMIT 250
```

new plan: `SCAN recommends ... → SCAN agg → SEARCH d USING INDEX (uri=?)`.
roughly ~6× fewer rows per refresh.

**why subquery-in-FROM and not CTE.** the same plan is achievable with
`WITH agg AS (...) SELECT ...`, but `zql.Query` (our comptime SQL parser)
walks forward to find the first `SELECT / FROM` pair to extract column
metadata. a `WITH … AS (SELECT … FROM …)` prefix would trip it into
parsing the inner SELECT. subquery-in-`FROM` keeps the outer SELECT
first in the source text and the parser happy.

**author/curator variants kept the naive shape.** those queries are not
cached (live, per-user) and their `WHERE d.did = ?` filter already
narrows the document side to a handful of rows, so the rewrite would
buy nothing.

**cache interval bumped from 5 min → 30 min.** leaderboards are
slow-changing. combined ~36× row-read reduction at this scale.

## phase 2 (planned, then dropped)

original plan was a denormalized `doc_recommend_counts(doc_uri PK,
count_24h, count_7d, count_30d, count_all, last_recommended_at)` table
maintained incrementally on tap insert/delete. with phase 1 in place this
is unnecessary at current scale — `recommends` is 2.6k rows growing at
~16/day, and the rewritten query is plenty fast. revisit only if
recommends grows ~50× (~130k rows).

the rollup was attractive *before* the query rewrite, when the SCAN was
forced. once the SCAN became proportional to the small table instead of
the corpus, the rollup's maintenance + decay-job overhead would have
exceeded what it saves.

## side quest: the reconciler url_dead crash

while measuring before/after, the reconciler started crash-looping every
~4–5 min — `attempt to use null value` at `std/http/Client.zig:1826`
from `reconciler.zig:384 checkDocUrl`. zig 0.16's `std.http.Client.fetch`
mishandles certain HEAD redirect chains (reproduced locally against
blog.karashiiro.moe's auth-callback bounce: cross-domain → back-to-origin
→ relative, exactly 3 hops at the default `redirect_behavior=3` limit).
the panic bypasses the `catch return .url_skip` and kills the worker
thread.

since this also blocked the reconciler's *primary* job (PDS verification
+ stale-doc soft-delete), the immediate fix was a kill switch:
`RECONCILE_URL_CHECK_ENABLED` (default `false`). pds verification runs
unconditionally; the `url_dead` HEAD check is opt-in until the stdlib
bug is worked around. see [reconciliation.md](reconciliation.md) for the
full reconciler shape.

## the takeaway

three lessons worth keeping:

1. **`turso db inspect <db> --queries` is the right starting point** for
   "where's my row-read budget going" — far more pointed than the
   dashboard graphs. period-to-date numbers, parameterized form, so
   bind-variants collapse.
2. **`LIMIT 50` is not a free pass.** without a supporting index, the
   query scans every row before SLicing the LIMIT off the end. an
   indexed filter+sort can do the LIMIT bound right at the storage layer.
3. **JOIN order matters more than `FROM` order suggests.** SQLite's
   planner is happy to drive a SCAN from the big table even when the
   small table is the obvious choice. forcing the order by
   pre-aggregating the small one in a subquery is more reliable than
   `ANALYZE` or hoping the planner gets it right.

## related

- [docs/performance-saga.md](performance-saga.md) — the *latency* saga
  (otel-zig BatchSpanProcessor mutex contention)
- [docs/reconciliation.md](reconciliation.md) — reconciler shape +
  `url_dead` feature
- [docs/migrations.md](migrations.md) — how migration 015 was applied
- `~/tangled.org/zzstoatzz.io/notes/databases/turso.md` — the portable
  turso lessons (scan-the-small-table, export endpoints, --queries)
