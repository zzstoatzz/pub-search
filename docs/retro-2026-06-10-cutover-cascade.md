# retro: the cutover cascade (2026-06-09 → 06-10)

One evening: tap → ingester cutover, then a chain of outages that took ~6 hours
to fully stabilize. Every individual fix was correct; the night was long because
each fix removed a bottleneck that had been *masking* the next bug. This
document is the causal chain, the diagnostic failures, and what structurally
prevents (or doesn't prevent) recurrence.

## timeline (commits are the spine)

| time (CDT) | event |
|---|---|
| 16:59 | `95ea51b` ingester verifies commits (sig + MST diff inversion) |
| 17:24 | `b170d46` cutover blockers: IPv6 bind, disconnect ring buffer |
| 17:28 | `e68370f` **cutover**: backend consumes ingester; tap stopped |
| 17:33 | prod freeze #1: sync DID resolve hung the firehose thread (~3 min, restart) |
| 17:37 | `f63325a` resolves on detached threads, 10s deadline |
| 17:42 | `fe39c87` heartbeat + watchdog (backend sat ~13 min on a half-open socket) |
| 20:17 | `96b5e86` **FTS fix #1**: turso `DELETE FROM documents_fts WHERE uri=?` was a 16s full scan per record; worker 4.6 → 47 docs/min |
| 22:05 | `468afd1` cursor checkpoints delivery position (351 events had been silently lost) |
| 22:33 | `d95bea4` **FTS fix #2**: local sync had the same scan, 330–528s cycles under the new throughput → stats/dashboard wedge |
| 23:39 | `e4e74e5` keep_alive=false for turso (poisoned-socket theory) — **made it worse** |
| 23:54 | `e8ca16f` dashboard + timeline served from background-refreshed cache |
| 00:05 | `605aa1d` **revert** keep_alive=false: DNS-per-query → transient errors → latent otel segfault → SIGABRT crash loop |
| 00:23 | `1a4a414` /stats serves last-known-good instead of live turso fallback |
| 00:40 | final soak: 59/60 then (post-`1a4a414`) clean; zero crashes |

## the causal chain

1. **Day-one latent bug**: `documents_fts` deletes by `uri` (UNINDEXED — FTS5
   cannot seek it) are O(corpus). Harmless at 5k docs in January; 16s/record
   once the patent bot tripled the corpus in early June. It existed in TWO
   places (turso indexer + local sync) and had to be found twice.
2. **The cutover didn't break anything — it removed the anesthesia.** tap
   delivered ~30% of events; the backend's 13s/record write path could keep up
   with a lossy feed. The verified ingester delivered 100%, and the queue began
   shedding 60% — *visible* loss replacing *invisible* loss.
3. **Each throughput fix shifted load downstream.** Unclogging the turso write
   path (16s → 0.4s) 10x'd the rows per local sync cycle, which blew up the
   local FTS scans (the same bug, other copy), which held the local write lock
   for minutes, which wedged stats/dashboard.
4. **The poisoned-socket disease is real but its cure was worse.** zig's http
   client has no timeouts; a pooled turso connection that the far side silently
   closed makes the next request hang *forever*. But `keep_alive=false` meant
   DNS-per-query, transient `NameServerFailure`s — and the otel span error path
   has a latent segfault (`attributes.zig` `initOwnedSlice` during `end()`
   after `recordError`) that pooled connections never triggered **because hung
   sockets never produce errors**. Crash loop. Reverted.
5. **Stable end state**: pooled connections (rare silent hangs, mitigated) +
   heavy endpoints (`/api/dashboard`, `/api/timeline`, `/stats`) served from
   background-refreshed snapshots so the request path rarely touches turso at
   all. 90-probe soak clean.

## why diagnosis took so long

These are the transferable lessons; the bugs themselves are fixed.

- **Fake 200s from the frontend domain.** `pub-search.waow.tech` has NO API
  proxy — `functions/[[path]].js` only rewrites OG tags, and unknown paths
  return the SPA HTML with status 200. Probing `pub-search.waow.tech/api/*`
  and trusting the status code without reading the body produced an hour of
  "it's fine from here" gaslighting while the browser (which calls
  `leaflet-search-backend.fly.dev` *directly* — see `dashboard.js:1`) hung.
  **Rule: a 200 is not evidence until you've seen the body, and the probe path
  must be the browser's path.**
- **Spans only exist when they end.** Zero `http.search` records in logfire
  looked like "no traffic"; it meant every request was hanging *inside* the
  handler. Absence of telemetry from a live system is itself a signal — of
  hanging, not idleness.
- **`/health` lies by design.** It touches nothing. The split that actually
  diagnoses: memory/cache-backed endpoints fast + every turso-touching endpoint
  hanging = a sick shared resource, not a sick process.
- **Two copies of the same bug.** The FTS scan was fixed on the turso side at
  20:17 and re-diagnosed nearly from scratch on the local side at 22:33.
  When a pattern is found, grep for *every* instance before declaring.
- **Declaring recovery during the quiet phase of a flap.** Twice. The wedge
  had a period (sync cycles); probes between cycles looked healthy. Only
  multi-round soaks under live load count as verification.
- **stderr had the answer early.** `fly logs` showed `search.local unavailable`,
  sync cycle durations, and eventually the segfault trace directly. Logs
  before theorizing.

## will it happen again?

**Fixed structurally (won't recur):**
- FTS uri-delete scans: existence-gated in both copies; creates (the bulk)
  never pay the scan.
- Sync cycles holding the write lock for minutes: same fix; cycles are seconds.
- Heavy endpoints stalling the page: cache-served; request path doesn't wait
  on turso (`/popular` pattern, now also dashboard/timeline/stats).
- Ingester losses: delivery-position checkpoints + ring buffer + heartbeat/
  watchdog pair; relay replay covers any gap ≤ relay retention.

**Will recur unless the scheduled work lands (the honest list):**
1. **Poisoned-socket hangs** — still in the code, just rare and mostly behind
   caches now. The real fix is socket-level deadlines or `keep_alive=false`,
   both blocked on: the **otel error-path segfault** (logfire-zig/otel dep).
   Fix that first; everything else unlocks.
2. **FTS deletes on *updates* still scan.** The principled fix is a
   rowid-keyed / external-content FTS table (zug migration) making all FTS
   maintenance O(1). Gets more urgent as the corpus grows (see: backfill plan).
3. **`/tags` is uncached** and flapped once under peak load. Same one-hour
   cache treatment when it matters.
4. **Boot window**: every backend deploy has a short span where the local
   replica isn't ready and keyword search falls back to turso. Tolerable;
   would vanish if `is_ready` were persisted/checked against the existing db
   instead of waiting for the first sync cycle.

## the structural takeaway

Typeahead's retro said it for the read path: *no request may do work
proportional to corpus size.* This night proved the write-path corollary:
**no per-record ingest operation may do work proportional to corpus size,
and no request handler may share a lock or a connection pool with one that
does.** Every wedge tonight was one of those two sentences.
