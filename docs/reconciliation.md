# reconciliation (stale document cleanup)

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
400/404 → delete from turso + tpuf (record is gone)
5xx/timeout → skip                 (PDS might be temporarily down)
```

at ~12k documents, 50 per cycle every 30 minutes, the full index is verified in ~5 days. documents older than 7 days are re-verified.

## what it fixes

**historical drift (the main problem):** documents deleted while the tap was down are detected and cleaned up. this is the only mechanism that catches these — tap resync can't.

**forward-looking vector leak:** the tap.zig delete handler now also calls `tpuf.delete()`, so future firehose deletes clean both turso and turbopuffer.

## files

| file | role |
|------|------|
| `backend/src/ingest/reconciler.zig` | background worker (~250 lines) |
| `backend/src/main.zig` | wires up `ingest.reconciler.start(allocator, io)` after `tpuf.init()` |
| `backend/src/db/migrations.zig` | `verified_at` column (in migration `001_initial_schema` — see [migrations.md](migrations.md)) |
| `backend/src/ingest/tap.zig` | `tpuf.delete()` after `indexer.deleteDocument()` |

## configuration

all env vars with sensible defaults — no configuration required for normal operation.

| variable | default | description |
|----------|---------|-------------|
| `RECONCILE_ENABLED` | `true` | kill switch — set to `false` to disable entirely |
| `RECONCILE_INTERVAL_SECS` | `1800` | seconds between cycles (30 min) |
| `RECONCILE_BATCH_SIZE` | `50` | documents checked per cycle |
| `RECONCILE_REVERIFY_DAYS` | `7` | re-verify documents older than N days |

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
