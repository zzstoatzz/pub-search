# performance saga (feb 2026)

## what happened

attempted to add a vector similarity search feature using voyage-3-lite embeddings (512 dims) stored in turso with a DiskANN index. the embedding model change had a different shape than what was stored, turso performance degraded badly, and multiple attempts to back out the changes failed to restore performance.

## the problems we found and fixed

### 1. vector similarity saturating turso

the `/similar` endpoint was doing brute-force `vector_distance_cos` queries on turso. each call took 10-15 seconds and blocked turso for all other queries. this meant keyword search (which falls back to turso when local isn't ready) took 30-57 seconds.

**fix**: neutered `/similar` to return `[]` immediately. removed all vector similarity code from search.zig (~150 lines). commit `d179d20`.

**result**: search dropped from 19.6s avg / 185s max → sub-second.

### 2. sqlite read/write lock contention

a single sqlite connection (`conn`) was shared between search queries and sync writes, protected by a mutex. during sync batch writes, search queries blocked waiting for the lock.

**fix**: added a separate read-only connection (`read_conn`) opened with `ReadOnly` flags. search queries use `read_conn` (no mutex needed). writes still use `conn` with mutex. WAL mode guarantees readers never block on writers. commit `1268461`.

**result**: `db.local.query` consistently 0-0.4ms.

### 3. missing instrumentation

had no visibility into the HTTP connection lifecycle. couldn't tell where time was spent between client request and server processing.

**fix**: added `http.request` span wrapping the full request lifecycle, `queue_ms` tracking pool queueing time, `receive_ms` tracking `receiveHead()` latency, and slow-receive warnings.

### 4. missing publication_uri index

the base_path FTS query joins `documents → publications → publications_fts`. without an index on `documents.publication_uri`, sqlite did a full table scan (5752 rows) for each publication match. for "test" (many matches), this caused ~600ms delays during iteration.

**fix**: added `CREATE INDEX IF NOT EXISTS idx_documents_publication_uri ON documents(publication_uri)` in LocalDb.zig createSchema().

**result**: "test" query dropped from ~1.5s → ~100ms.

### 5. HTTP write buffer too small

`HTTP_BUF_SIZE` was 8192 (8KB). for large responses (32KB for "test"), zig's HTTP server needed multiple flush cycles to write the response, each involving a syscall.

**fix**: increased `HTTP_BUF_SIZE` to 65536 (64KB). a 32KB response now fits in a single flush.

### 6. sqlite read connection tuning

added `PRAGMA mmap_size=268435456` (256MB) and `PRAGMA cache_size=-20000` (20MB) on the read connection so FTS5 index pages stay in memory.

## what we know now (instrumented)

added `search.iterate.*` spans around each iteration loop in `searchLocal()`. this revealed:

server-side processing is fast:
- `db.local.query` (prepare): 0.2ms per query
- `search.iterate.docs_fts` (40 rows + snippet + JSON): **2ms**
- `search.iterate.base_path`: 0.3ms
- `search.iterate.pubs_fts`: 0.3ms
- total actual work: **~3ms**

but `http.search` intermittently shows 1-3 seconds. the gap occurs between two consecutive lines of code (after `local.query()` returns, before the iteration span starts). there is literally nothing in between — no I/O, no allocations, no function calls.

### what we ruled out

- **snippet() overhead**: replaced with `substr(d.content, 1, 200)` — spikes still occurred. reverted. snippet is not the cause.
- **iteration overhead**: spans prove all 3 iteration loops complete in ~3ms total
- **logfire span.end() blocking**: logfire-zig uses `BatchSpanProcessor` (async, 500ms interval). span.end() just queues — no synchronous I/O.
- **query preparation**: db.local.query spans show 0.2ms consistently

### what it actually is

**CPU starvation on shared-cpu-1x Fly VM.** the thread gets preempted by the hypervisor for 1-2 seconds between two consecutive lines of code. the VM runs:
- 16 HTTP worker threads
- sync thread (turso → local batch writes)
- tap consumer thread (firehose processing)
- stats buffer thread (periodic turso flush)
- activity tracker thread
- BatchSpanProcessor thread (logfire export every 500ms, involves TLS + protobuf)

on a shared CPU with fractional allocation, all these threads compete. the BatchSpanProcessor's 500ms TLS flush is particularly suspect — TLS is CPU-intensive.

> **note (april 2026):** the backend now runs on zig 0.16 with thread-per-connection (Thread.Pool was removed). the thread count listed above is from the 0.15 era but the contention analysis still applies.

## possible next steps

1. **upgrade VM**: move to `performance-1x` (dedicated CPU) — this is the real fix
2. **reduce thread contention**: lower HTTP workers from 16, or reduce logfire export frequency
3. **reduce logfire spans in hot path**: fewer spans = less BatchSpanProcessor work = less CPU contention

## architecture (current)

```
client → fly proxy (TLS termination) → app (port 3000)
                                         ├── thread-per-connection (accept loop spawns threads)
                                         ├── local SQLite (read_conn for search, conn+mutex for writes)
                                         ├── turso client (fallback for unsupported queries)
                                         ├── sync thread (turso → local, full on startup + periodic incremental)
                                         ├── tap consumer (firehose → turso)
                                         ├── embedder (voyage-4-lite → turbopuffer, background)
                                         ├── stats buffer (periodic flush to turso)
                                         └── activity tracker
```

search path: `handleSearch` → `searchLocal` (3 FTS queries on read_conn, ~3ms total) → `sendJson` → `respond()` + `flush()`

hot path timing (when not CPU-starved): ~3-6ms end to end
hot path timing (when CPU-starved): 1-3 seconds (thread preempted between any two operations)

## resolution: otel-zig BatchSpanProcessor mutex contention

the "CPU starvation" theory above was wrong. Fly CPU utilization was at ~0-5% during the stalls — the CPU was idle, not saturated. the thread wasn't being preempted by the hypervisor; it was **blocked on a mutex**.

### root cause

otel-zig's `BatchSpanProcessor` (`src/sdk/trace/batch_span_processor.zig`) has a background thread that periodically exports queued spans to the logfire backend via OTLP/HTTP. the `exportThreadFn` called `exportBatchLocked()` which did the full HTTP export (TLS handshake + protobuf serialization + POST) **while holding the mutex**. the same mutex is acquired by `onEnd()`, which is called by every `span.end()`.

so every 500ms, the background thread would:
1. lock mutex
2. serialize all queued spans to protobuf
3. POST to logfire via HTTPS (1-2 seconds on a fly VM)
4. unlock mutex

any application thread calling `span.end()` during step 2-3 would block for the entire duration of the HTTP export. this explains the 1-3 second stalls appearing between arbitrary consecutive lines of code — the stall was in the `defer span.end()` of whichever logfire span happened to coincide with a batch flush.

### how we confirmed it

1. added `search.iterate.*` spans — proved all actual search work takes ~3ms
2. the 1-3s gap appeared between `db.local.query` span ending and the next span starting (i.e., inside `span.end()`)
3. disabled logfire entirely (`logfire.configure()` commented out) — stalls disappeared completely, all requests 75-110ms
4. Fly CPU graph showed ~0-5% utilization during stalls — ruled out CPU contention, pointed to lock contention

### the fix

in `otel-zig/src/sdk/trace/batch_span_processor.zig`, changed `exportThreadFn` to drain the queue under the lock, then release the lock before doing the HTTP export. same pattern that `forceFlush()` already used correctly.

before:
```
exportThreadFn: lock → export (HTTP POST, 1-2s) → unlock
onEnd:          lock (BLOCKED for 1-2s) → enqueue → unlock
```

after:
```
exportThreadFn: lock → drain queue → unlock → export (HTTP POST) → done
onEnd:          lock (instant) → enqueue → unlock
```

changes pushed through the dependency chain:
- `otel-zig` (zzstoatzz/otel-zig trunk): fix in `batch_span_processor.zig`
- `logfire-zig` (zzstoatzz.io/logfire-zig main): bumped otel-zig hash
- `leaflet-search` backend: bumped logfire-zig hash, re-enabled logfire

### final results

with logfire fully enabled and the fix applied:
- hello (21KB response): **75-112ms** consistently, 10/10 requests
- test (32KB response): **76-110ms** consistently, 10/10 requests
- zero multi-second stalls
- full observability retained
