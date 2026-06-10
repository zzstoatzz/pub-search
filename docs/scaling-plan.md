# scaling plan: surviving many multiples of corpus size

Written 2026-06-10, after the cutover cascade (`retro-2026-06-10-cutover-cascade.md`).
The goal: a corpus 10x today's (~500k+ docs) changes build costs, never serving
behavior. Informed by typeahead's rewrite (7M actors), adapted for the
difference that matters: we serve full-text AND semantic search over complete
documents, so our indexes can't collapse to capped point-lookups — but the
*request-time properties* can be identical.

## invariants (violations are outages, we proved each one)

1. **Background data movement never touches the serving box.** Not throttled —
   absent. (The 06-10 incident in one sentence.)
2. **No request does work proportional to corpus size.** (typeahead's law)
3. **No per-record ingest operation does work proportional to corpus size.**
   (the FTS-scan family)
4. **Every fetch is bounded in rows AND bytes.** Patent docs average ~24KB;
   row limits alone are not payload limits.
5. **Every retry loop must shrink its work, never grow it.** (the 7-hour
   window)
6. **A request may hang only as long as its timeout — and zig's http client
   has none**, so until deadlines exist (blocked on the otel error-path
   segfault), every remote call on a request path is a liability: cache it,
   or serve from local state.

## target architecture

```
firehose ──> ingester (verified, checkpointed) ──> backend worker ──> turso
                                                                        │
                              ┌────────────── offline ──────────────────┤
                              v                                         v
                       snapshot builder                          embedder ─> tpuf
                   (separate machine/process,                  (already offline;
                    paginated reads, builds                     vectors never
                    replica + FTS, sentinel                     touch serving)
                    checks, sha256 → R2)
                              │
                              v
        serving box: download → verify → ATTACH read-only → atomic swap
                     + live overlay (docs newer than snapshot; tiny FTS)
                     + background-refreshed caches for every aggregate
```

- **Snapshot builder**: batch job (builder mode of the backend binary, run as
  an ephemeral fly machine or via the prefect server). Reads turso with keyset
  pagination over the `(indexed_at, uri)` index, payload-bounded pages. Builds
  documents + FTS + tags + publications into a fresh sqlite file. Refuses to
  publish unless sentinel queries pass (known docs searchable, counts within
  tolerance of turso). Publishes `replica.db` + sha256 manifest to R2.
- **Serving box**: downloads, verifies hash + schema + sentinels, attaches
  read-only, swaps atomically. Readers never coexist with a bulk writer.
  Rollback = keep the previous snapshot file.
- **Live overlay**: between snapshots the backend's existing tap consumer also
  writes fresh docs to a small overlay db (only rows newer than the snapshot
  watermark — hundreds, not thousands). Queries merge snapshot + overlay
  results. The overlay is dropped at each swap. Freshness ≈ firehose latency;
  snapshot cadence only bounds how big the overlay gets.
- **In-place incremental sync is deleted**, not improved. `SYNC_DISABLE=1`
  stays until the swap path exists, with off-box catch-up
  (`scripts/offline-replica-catchup`) as the interim freshness mechanism.

## why this holds at 10x

| component | at 10x (~500k docs) |
|---|---|
| ingester | per-event work; corpus-size independent |
| backend worker → turso | per-record, index-backed (needs rowid-FTS migration to make updates O(1) too) |
| turso | row count fine; FTS table large but write path is seek-based post-migration |
| snapshot build | linear in corpus, but offline and schedulable — slow builds cost nothing user-visible |
| serving reads | bounded FTS/index queries against an immutable file; flat |
| semantic | already remote (tpuf) + offline (embedder); flat for serving |
| caches | refresh queries (COUNTs/GROUP BYs) grow linearly — move to counter tables / incremental aggregates before they're slow, they're off the request path either way |
| local box | snapshot is multi-GB at 10x: volume + RAM sizing is a build-time concern, or trim the replica (contentless FTS — only FTS needs content locally) |
| atlas | already OOM'd once; becomes a builder-side batch job like everything else |

## sequence

1. **Off-box catch-up + swap** (now): refresh the frozen replica, prod fresh
   and fast with sync still disabled.
2. **Snapshot builder productionized**: builder mode + R2 publish + verified
   swap in the backend. Cadence hourly to start.
3. **Live overlay** for sub-hour freshness.
4. **Delete in-place sync** (the code, not just the flag).
5. **rowid-keyed FTS migration** on turso (zug) — O(1) FTS maintenance for
   updates; prerequisite for backfill write volume.
6. **Backfill** (drivepatents ~75k, courtdaemon, long tail): writes go to
   turso via the throttled offline walker; serving notices nothing; the next
   snapshot picks them up. Patents visibility/embedding policy decided before
   this lands.
7. **otel error-path segfault fix** (logfire-zig/otel) — unlocks http
   deadlines / connection hygiene, retiring invariant 6's caveat.

## monitoring that matches the failure modes

- Freshness invariant alerting (exists: CI watchdog) — keep; it was the only
  detector that worked.
- Snapshot age + swap success/failure alerts once the builder exists.
- The verification standard from the retro applies to every "it's fixed":
  exact browser request set, bodies, parallel bursts, sustained windows,
  freshness.

## adoption lesson (2026-06-10 bridgy purge swap)

`openDb` runs a full `PRAGMA integrity_check` at boot — on a 365MB file on a
fly volume that's multiple minutes of `is_ready=false`, during which keyword
falls back to slow turso queries (3s+). The chunked upload already sha256-gates
the file before it becomes `local.db.new`, so the boot-time full scan is
redundant for adopted snapshots. When the builder lands (sequence #2): verify
hash at download time, run `quick_check` (page-structure only, seconds) at
adopt, and drop the full integrity_check from the boot path.
