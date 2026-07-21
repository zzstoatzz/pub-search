# reconciliation (stale document cleanup)

> This document describes the legacy row verifier. The corpus audit demonstrated
> that existence-only verification is insufficient: it cannot discover missing
> records or refresh changed ones. The replacement begins with the read-only,
> ledger-backed planner below; legacy verification remains active until apply mode
> has been canaried and promoted.

## repo-level corpus plan (dry-run phase)

`scripts/audit-corpus` enumerates authoritative current repo records and inventories
Turso, the adopted snapshot, and vectors into a resumable local checkpoint.
`scripts/reconcile-corpus` converts that checkpoint into a versioned SQLite run and
item ledger:

```sh
./scripts/audit-corpus
./scripts/reconcile-corpus \
  --audit-db /tmp/pub-search-corpus-audit.sqlite \
  --ledger /tmp/pub-search-corpus-reconcile.sqlite
```

Every item has a source CID, an explicit `create`, `update`, `verify`, `delete`,
`skip`, or `quarantine` action, a reason, and an `allow`, `review`, `exclude`, or
`quarantine` policy decision. Each repo plan records current classifier state and a
per-repo create cap. The ledger is content-addressed to the audit checkpoint and a
completed run is immutable unless the operator explicitly uses `--replace`.

Safety properties:

- no production write path or apply flag exists in this phase;
- banned and Bridgy policy is preserved;
- bulk-generated labels exclude historical creates, while unknown/observing/pending
  authors remain review-gated;
- definitive source absence proposes deletion, but unreachable sources quarantine;
- content, canonical, and cross-collection duplicates remain intentional skips;
- metadata-only documents remain pending until their ranking/document type ships;
- more than 250 creates in one repo forces review even after a classifier allow.

The audit and first full ledger are recorded in
[`corpus-audit-2026-07-20.md`](corpus-audit-2026-07-20.md).

the firehose is our only way to learn about ATProto record deletions. it's ephemeral — if the tap is down when a delete event comes through, the record becomes a ghost in turso (and turbopuffer) forever. the reconciler fixes this by periodically verifying documents still exist at their source PDS.

## the problem

tap's resync only re-sends records that *exist* — it never emits delete events for records that disappeared. even forcing a full repo re-crawl (remove + re-add) only adds current records; it doesn't clean up ghosts. we confirmed this by reading indigo/tap source (`resyncer.go`, `firehose.go`).

additionally, `deleteDocument()` in indexer.zig only cleaned turso — it never deleted the corresponding turbopuffer vector. so even when deletes *were* processed via the firehose, vectors accumulated forever.

a real user reported this: they deleted and re-published blog posts weeks ago, but our index still had the old versions with broken URLs.

## how it works

```
reconciler (background thread, every 30 min)
     ↓
fetch 50 docs from turso (oldest verified_at first, NULLs = never checked)
     ↓ for each doc
parse AT-URI → (did, collection, rkey)
     ↓
resolve DID → PDS endpoint via plc.directory (cached across cycles)
     ↓
GET {pds}/xrpc/com.atproto.repo.getRecord?repo={did}&collection={collection}&rkey={rkey}
     ↓
200 → update verified_at          (record still exists)
       + optional: HEAD the destination URL → mark url_dead on 404
400/404 → delete from turso + tpuf (record is gone)
5xx/timeout → skip                 (PDS might be temporarily down)
```

at ~18k documents, 50 per cycle every 30 minutes, the full index is verified in ~7-8 days. documents older than 7 days are re-verified.

backed by `idx_documents_verified_at` (migration 015) so the batch fetch is an index range scan, not a full-table scan — see [access-pattern-audit.md](access-pattern-audit.md).

## what it fixes

**historical drift (the main problem):** documents deleted while the tap was down are detected and cleaned up. this is the only mechanism that catches these — tap resync can't.

**forward-looking vector leak:** the ingester.zig delete handler now also calls `tpuf.delete()`, so future firehose deletes clean both turso and turbopuffer.

## files

| file | role |
|------|------|
| `backend/src/ingest/reconciler.zig` | background worker (~250 lines) |
| `backend/src/main.zig` | wires up `ingest.reconciler.start(allocator, io)` after `tpuf.init()` |
| `backend/src/db/migrations.zig` | `verified_at` column (in migration `001_initial_schema` — see [migrations.md](migrations.md)) |
| `backend/src/ingest/ingester.zig` | `tpuf.delete()` after `indexer.deleteDocument()` |

## configuration

all env vars with sensible defaults — no configuration required for normal operation.

| variable | default | description |
|----------|---------|-------------|
| `RECONCILE_ENABLED` | `true` | kill switch — set to `false` to disable entirely |
| `RECONCILE_INTERVAL_SECS` | `1800` | seconds between cycles (30 min) |
| `RECONCILE_BATCH_SIZE` | `50` | documents checked per cycle |
| `RECONCILE_REVERIFY_DAYS` | `7` | re-verify documents older than N days |
| `RECONCILE_URL_CHECK_ENABLED` | `false` | gate the destination-URL HEAD check (the `url_dead` feature). off by default while a `std.http.Client` redirect panic is worked around — see "url_dead and the http.Client panic" below. PDS verification + soft delete run unconditionally regardless. |

## failure modes

the reconciler is designed to degrade gracefully — it can never break search or indexing.

| scenario | behavior |
|----------|----------|
| turso down | `error.NoClient` → logged, exponential backoff |
| plc.directory down | all PDS lookups return null → entire batch skipped, no deletes |
| PDS down (5xx/timeout) | `error_skip` → doc not deleted, not verified, retried next cycle |
| turbopuffer down | `tpuf.delete` errors caught → turso deletes still happen |
| reconciler thread panics | isolated thread — search/indexing/embedding unaffected |

the reconciler never deletes on ambiguity. only a definitive 400 or 404 from the PDS triggers deletion. any error or timeout means "skip and retry later."

## race conditions

**tap creates doc while reconciler deletes it:** safe. `insertDocument`'s `ON CONFLICT` handles re-creation — the document comes right back on the next tap event.

**reconciler and tap both delete the same doc:** safe. `deleteDocument` and `tpuf.delete` are both idempotent.

## observability

- **fly logs:** `reconcile: background worker started` on boot, `reconcile: verified N documents, deleted M` after each cycle with activity
- **logfire:** `reconcile.cycle` span covers each full cycle. `reconcile: deleted stale document: {uri}` logged for each deletion.
- **turso:** `verified_at` column shows when each document was last verified. `NULL` = never checked.

### checking reconciler status

```bash
# verify it started
fly logs -a leaflet-search-backend --no-tail | grep reconcile

# check verified_at coverage (how many docs have been checked)
# via turso shell or dashboard query:
# SELECT COUNT(*) as total, COUNT(verified_at) as verified FROM documents
```

## design decisions

**why not use tap resync?** tap resync only sends records that exist. it never sends delete events for records that disappeared. even removing and re-adding a repo only backfills current records — it doesn't identify what was deleted since the last sync.

**why check the PDS directly?** the PDS is the authoritative source. `com.atproto.repo.getRecord` returns the record if it exists, or 400/404 if it doesn't. no middleman, no ambiguity.

**why cache PDS endpoints?** many documents share the same author (DID). resolving the PDS once per DID and caching it avoids redundant plc.directory lookups. the cache persists for the lifetime of the worker thread.

**why 200ms rate limiting?** PDSs are shared infrastructure. we check 50 documents per cycle at most — aggressive polling would be antisocial. 200ms between requests is conservative.

**why compute timestamps in zig?** turso's handling of `strftime` with parameterized modifiers is untested in this codebase. computing timestamps in zig (same approach as the embedder) eliminates that risk.

## url_dead and the http.Client panic

a secondary feature on top of PDS verification: HEAD the destination URL we'd link to. on a 404, set `documents.url_dead = 1` so search excludes the doc without deleting it (delete-on-404 would flap — tap re-inserts on the next resync, since `insertDocument` doesn't consult tombstones).

**status: opt-in via `RECONCILE_URL_CHECK_ENABLED=true`.** the implementation calls `std.http.Client.fetch` with `.method = .HEAD`, and zig 0.16's stdlib mishandles certain redirect chains — `attempt to use null value` at `std/http/Client.zig:1826`. reproduced locally against `blog.karashiiro.moe`'s auth-callback bounce (cross-domain → back-to-origin → relative, exactly 3 hops at the default `redirect_behavior=3` limit). the panic bypasses our `catch return .url_skip` and kills the worker thread; in production this crash-looped the reconciler for 5+ hours before we noticed, blocking PDS verification entirely.

**workaround.** the kill switch keeps the secondary feature off by default until the stdlib bug is worked around. options for a real fix:

- subprocess `curl -I` (simple, slow, leaves a fork-per-doc footprint)
- raw socket HEAD without redirect-following (skip the codepath that panics; treat redirects as `.url_skip`)
- upgrade zig + retry (only viable when 0.17+ ships and `std.http.Client` is reworked)

**how to re-enable when fixed.** flip `RECONCILE_URL_CHECK_ENABLED=true` via `fly secrets`. the cycle log will then include `reconcile: marked url_dead: {uri} → {url}` entries when a destination 404s.
