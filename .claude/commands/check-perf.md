# check performance via logfire

use `mcp__logfire__arbitrary_query` with `age` in minutes (max 43200 = 30 days).

note: `duration` is in seconds (DOUBLE PRECISION), multiply by 1000 for ms.

## latency percentiles by endpoint
```sql
SELECT span_name,
       COUNT(*) as count,
       ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY duration) * 1000, 2) as p50_ms,
       ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration) * 1000, 2) as p95_ms,
       ROUND(PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY duration) * 1000, 2) as p99_ms
FROM records
WHERE span_name LIKE 'http.%'
GROUP BY span_name
ORDER BY count DESC
```

## slow requests with trace IDs
```sql
SELECT span_name, duration * 1000 as ms, trace_id, start_timestamp
FROM records
WHERE span_name LIKE 'http.%' AND duration > 0.1
ORDER BY duration DESC
LIMIT 20
```

## trace breakdown (drill into slow request)
```sql
SELECT span_name, duration * 1000 as ms, message, attributes->>'sql' as sql
FROM records
WHERE trace_id = '<TRACE_ID>'
ORDER BY start_timestamp
```

## database comparison (turso vs local)
```sql
SELECT
  CASE WHEN span_name = 'db.query' THEN 'turso'
       WHEN span_name = 'db.local.query' THEN 'local' END as db,
  COUNT(*) as queries,
  ROUND(AVG(duration) * 1000, 2) as avg_ms,
  ROUND(MAX(duration) * 1000, 2) as max_ms
FROM records
WHERE span_name IN ('db.query', 'db.local.query')
GROUP BY db
```

## recent errors
```sql
SELECT start_timestamp, span_name, exception_type, exception_message
FROM records
WHERE exception_type IS NOT NULL
ORDER BY start_timestamp DESC
LIMIT 10
```

## traffic pattern (requests per minute)
```sql
SELECT date_trunc('minute', start_timestamp) as minute,
       COUNT(*) as requests
FROM records
WHERE span_name LIKE 'http.%'
GROUP BY minute
ORDER BY minute DESC
LIMIT 30
```

## search query distribution
```sql
SELECT attributes->>'query' as query, COUNT(*) as count
FROM records
WHERE span_name = 'http.search' AND attributes->>'query' IS NOT NULL
GROUP BY query
ORDER BY count DESC
LIMIT 20
```

## typical workflow
1. run latency percentiles to get baseline
2. if p95/p99 high, find slow requests with trace IDs
3. drill into specific trace to see which child spans are slow
4. check db comparison to see if turso calls are the bottleneck
