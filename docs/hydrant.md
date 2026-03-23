# hydrant: potential tap replacement

evaluated 2026-03-22. **decision: not adopting now**, but worth revisiting.

## what is hydrant

[hydrant](https://tangled.org/did:plc:dfl62fgb7wtjj3fcbb72naae/hydrant) is a Rust-based
ATProto indexer/sync tool by [ptr.pet](https://90008.leaflet.pub/3mhp3t4kuw22e). it handles
firehose consumption, record persistence, backfill, and event streaming — a superset of what
tap does for us today.

## what we'd gain

- **cursor-based event replay** — clients own the cursor, no server-side ACK state. eliminates
  the class of bugs that led to our ProcessQueue workaround in `tap.zig` (ACK blocking, outbox
  growth, drop-on-overflow)
- **runtime filter management** — `PATCH /filter` to add/remove collections without redeploying
  (tap's filters are fixed at startup)
- **multiple firehose sources** — subscribe to multiple relays simultaneously; we're currently
  locked to a single relay
- **ephemeral mode** — `HYDRANT_EPHEMERAL=true` with a TTL keeps only a rolling window of
  events, avoiding permanent disk accumulation. fits our use case since turso is our source of
  truth, not hydrant's local store
- **~3x throughput** — ~60k records/sec vs tap's 22-34k (network-bound at 100Mbps)

## why not now

- **we've already worked around tap's pain points** — the ProcessQueue pattern works, memory is
  managed with `TAP_RESYNC_PARALLELISM=1` and 2GB RAM, the ACK model is stable
- **hydrant is more than we need** — it persists records in fjall (LSM-tree), implements XRPC
  queries, stores blocks as CBOR. even in ephemeral mode that's a lot of machinery to relay
  events. tap is simpler for our use case
- **no Docker image** — builds via Nix only. we'd need to create and maintain our own Dockerfile
  for Fly.io. tap is `ghcr.io/bluesky-social/indigo/tap:latest` with zero build effort
- **single maintainer, explicitly unstable DB format** — fjall dependency is patched, breaking
  changes expected. tap is maintained by the Bluesky team (indigo)
- **`tap.zig` rewrite** — hydrant's WebSocket message format differs from tap's. our ~450-line
  consumer would need rewriting. not huge, but not free
- **throughput is irrelevant for us** — we index a tiny slice of the network (5 collection types),
  not the full firehose

## when to revisit

- if we need **multiple relay sources** (partial relays, PDS-direct connections)
- if we need **runtime collection management** (adding new platforms without redeploying tap)
- if tap's maintenance slows down or indigo deprecates it
- if hydrant gets **Docker images** and a **stable storage format**
- if hydrant's **XRPC record queries** could replace our reconciler's PDS-direct lookups

## integration sketch (for future reference)

if we do adopt, the simplest path:

1. run hydrant on Fly.io with ephemeral mode and our collection filters
2. rewrite `tap.zig` consumer to connect to hydrant's `/stream?cursor=N` WebSocket
3. persist cursor locally (e.g. in turso or a file) for crash recovery
4. remove ProcessQueue — cursor replay makes it unnecessary
5. keep everything else (extractor, indexer, embedder, reconciler) as-is

hydrant's message format:
```json
{
  "id": 12345,
  "type": "record",
  "record": {
    "live": true,
    "did": "did:plc:abc123",
    "collection": "site.standard.document",
    "rkey": "3mhp3t4kuw22e",
    "action": "create",
    "record": { ... },
    "cid": "bafyrei..."
  }
}
```

the `action` field maps directly to our existing create/update/delete dispatch in `tap.zig`.
