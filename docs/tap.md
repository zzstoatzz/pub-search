> **HISTORICAL (since 2026-06-09):** tap was replaced by our own firehose
> ingester (`ingester/`) — same `/channel` websocket protocol, plus
> cryptographic verification of every commit (which is what keeps bridgy fed
> out of the corpus). The tap fly machine is STOPPED, kept only for rollback.
> This doc remains as reference for the protocol and for anyone running tap
> elsewhere.

# tap (firehose sync)

leaflet-search uses [tap](https://github.com/bluesky-social/indigo/tree/main/cmd/tap) from bluesky-social/indigo to receive real-time events from the ATProto firehose.

## what is tap?

tap subscribes to the ATProto firehose, filters for specific collections (e.g., `site.standard.document`), and broadcasts matching events to websocket clients. it also does initial crawling/backfilling of existing records.

key behavior: **tap backfills historical data when repos are added**. when a repo is added to tracking:
1. tap fetches the full repo from the account's PDS using `com.atproto.sync.getRepo`
2. live firehose events during backfill are buffered in memory
3. historical events (marked `live: false`) are delivered first
4. after historical events complete, buffered live events are released
5. subsequent firehose events arrive immediately marked as `live: true`

tap enforces strict per-repo ordering - live events are synchronization barriers that require all prior events to complete first.

## message format

tap sends JSON messages over websocket. record events look like:

```json
{
  "type": "record",
  "record": {
    "live": true,
    "did": "did:plc:abc123...",
    "rev": "3mbspmpaidl2a",
    "collection": "site.standard.document",
    "rkey": "3lzyrj6q6gs27",
    "action": "create",
    "record": { ... },
    "cid": "bafyrei..."
  }
}
```

### field types (important!)

| field | type | values | notes |
|-------|------|--------|-------|
| type | string | "record", "identity", "account" | message type |
| action | **string** | "create", "update", "delete" | NOT an enum! |
| live | bool | true/false | true = firehose, false = resync |
| collection | string | e.g., "site.standard.document" | lexicon collection |

## gotchas

1. **action is a string, not an enum** - tap sends `"action": "create"` as a JSON string. if your parser expects an enum type, extraction will silently fail. use string comparison.

2. **collection filters apply during processing** - `TAP_COLLECTION_FILTERS` controls which records tap processes and sends to clients, both during live commits and resync CAR walks. records from other collections are skipped entirely.

3. **signal collection vs collection filters** - `TAP_SIGNAL_COLLECTION` controls auto-discovery of repos (which repos to track), while `TAP_COLLECTION_FILTERS` controls which records from those repos to output. a repo must either be auto-discovered via signal collection OR manually added via `/repos/add`.

4. **silent extraction failures** - if using zat's `extractAt`, enable debug logging to see why parsing fails:
   ```zig
   pub const std_options = .{
       .log_scope_levels = &.{.{ .scope = .zat, .level = .debug }},
   };
   ```
   this will show messages like:
   ```
   debug(zat): extractAt: parse failed for Op at path { "op" }: InvalidEnumTag
   ```

## memory and performance tuning

tap loads **entire repo CARs into memory** during resync. some bsky users have repos that are 100-300MB+. this causes spiky memory usage that can OOM the machine.

### recommended settings for leaflet-search

```toml
[[vm]]
  memory = '2gb'  # 1gb is not enough

[env]
  TAP_RELAY_URL = 'https://zlay.waow.tech'   # custom relay (not default bsky.network)
  TAP_RESYNC_PARALLELISM = '1'               # only one repo CAR in memory at a time (default: 5)
  TAP_FIREHOSE_PARALLELISM = '5'             # concurrent event processors (default: 10)
  TAP_OUTBOX_CAPACITY = '10000'              # event buffer size (default: 100000)
  TAP_IDENT_CACHE_SIZE = '10000'             # identity cache entries (default: 2000000)
  TAP_CURSOR_SAVE_INTERVAL = '5s'            # how often to persist firehose cursor
  TAP_REPO_FETCH_TIMEOUT = '600s'            # timeout for repo CAR fetches
```

### why these values?

- **2GB memory**: 1GB causes OOM kills when resyncing large repos
- **resync parallelism 1**: prevents multiple large CARs in memory simultaneously
- **lower firehose/outbox**: we track ~1000 repos, not millions - defaults are overkill
- **smaller ident cache**: we don't need 2M cached identities

if tap keeps OOM'ing, check logs for large repo resyncs:
```bash
fly logs -a leaflet-search-tap | grep "parsing repo CAR" | grep -E "size\":[0-9]{8,}"
```

## quick status check

from the `tap/` directory:
```bash
just check
```

shows tap machine state, most recent indexed date, and 7-day timeline. useful for verifying indexing is working after restarts.

example output:
```
=== tap status ===
app    781417db604d48  23  ewr  started  ...

=== Recent Indexing Activity ===
Last indexed: 2026-01-08 (14 docs)
Today: 2026-01-11
Docs: 3742 | Pubs: 1231

=== Timeline (last 7 days) ===
2026-01-08: 14 docs
2026-01-07: 29 docs
...
```

if "Last indexed" is more than a day behind "Today", tap may be down or catching up.

## checking catch-up progress

when tap restarts after downtime, it replays the firehose from its saved cursor. to check progress:

```bash
# see current firehose position (look for timestamps in log messages)
fly logs -a leaflet-search-tap | grep -E '"time".*"seq"' | tail -3
```

the `"time"` field in log messages shows how far behind tap is. compare to current time to estimate catch-up.

catch-up speed varies:
- **~0.3x** when resync queue is full (large repos being fetched)
- **~1x or faster** once resyncs clear

## debugging

### check tap connection
```bash
fly logs -a leaflet-search-tap --no-tail | tail -30
```

look for:
- `"connected to firehose"` - successfully connected to bsky relay
- `"websocket connected"` - backend connected to tap
- `"dialing failed"` / `"i/o timeout"` - network issues

### check backend is receiving
```bash
fly logs -a leaflet-search-backend --no-tail | grep -E "(tap|indexed)"
```

look for:
- `tap connected!` - connected to tap
- `tap: msg_type=record` - receiving messages
- `indexed document:` - successfully processing

### common issues

| symptom | cause | fix |
|---------|-------|-----|
| tap machine stopped, `oom_killed=true` | large repo CARs exhausted memory | increase memory to 2GB, reduce `TAP_RESYNC_PARALLELISM` to 1 |
| `websocket handshake failed: error.Timeout` | tap not running or network issue | restart tap, check regions match |
| `dialing failed: lookup ... i/o timeout` | DNS issues reaching bsky relay | restart tap, transient network issue |
| messages received but not indexed | extraction failing (type mismatch) | enable zat debug logging, check field types |
| repo shows `records: 0` after adding | resync failed or collection not in filters | check tap logs for resync errors, verify `TAP_COLLECTION_FILTERS` |
| new platform records not appearing | platform's collection not in `TAP_COLLECTION_FILTERS` | add collection to filters, restart tap |
| indexing stopped, tap shows "started" | tap catching up from downtime | check firehose position in logs, wait for catch-up |
| indexing dead, tap "started", `/stats/{cursors,outbox-buffer,resync-buffer}` all frozen across two polls | tap process wedged (e.g. after a relay rebuild) | `fly machine restart <id> -a leaflet-search-tap` — firehose resumes from saved cursor |
| crawler logs `failed to list repos by collection: HTTP 400 ... cursor was not valid` | relay rebuilt → stale enumeration cursor in old format | clear it (see below); restart not needed |

### relay rebuild → stale crawler cursor

If the relay (`zlay.waow.tech`) is rebuilt, its `listReposByCollection`
cursor format can change (old builds returned an opaque binary cursor, newer
ones a bare `did:plc:...`). The tap persists the old cursor in
`collection_cursors` and keeps re-sending it → relay 400s → the crawler can't
enumerate (new-repo discovery + quiet-repo re-backfill stop). The realtime
firehose is unaffected. Fix by clearing the stale row so the crawler
enumerates fresh (`getCollectionCursor` returns "" when absent):

```sh
fly ssh console -a leaflet-search-tap
apk add --no-cache sqlite          # not in the image by default
sqlite3 /data/tap.db "DELETE FROM collection_cursors WHERE url='https://zlay.waow.tech'"
```

Safe to run live — the crawler only *writes* the cursor on a successful
batch (which isn't happening while it 400s), so no write race. Within ~1 min
`/stats/cursors` `list_repos` flips to a bare DID and the 400s stop. This
re-enumerates the whole network → a one-time full resync sweep; use
`just turbo` to drain it, then `just normal`. Recovery of any ingestion gap
goes through tap's own resyncer (firehose `PrevData`-mismatch trigger +
crawler), **except repos whose own PDS is down** — tap resyncs from the PDS,
not the relay, so those wait for the PDS to return.

A logfire alert (`tap ingestion stalled (no index_record in 1h)`, project
`pub-search`) fires when zero `tap.index_record` spans land in an hour — wire
a notification channel to it so a stall pages instead of going unnoticed.

## tap API endpoints

tap exposes HTTP endpoints for monitoring and control:

| endpoint | description |
|----------|-------------|
| `/health` | health check |
| `/stats/repo-count` | number of tracked repos |
| `/stats/record-count` | total records processed |
| `/stats/outbox-buffer` | events waiting to be sent |
| `/stats/resync-buffer` | buffered commits for repos currently resyncing (NOT the resync queue) |
| `/stats/cursors` | firehose cursor position |
| `/info/:did` | repo status: `{"did":"...","state":"active","records":N}` |
| `/repos/add` | POST with `{"dids":["did:plc:..."]}` to add repos |
| `/repos/remove` | POST with `{"dids":["did:plc:..."]}` to remove repos |

**note:** the tap container has no `curl` — use `wget` instead.

example: check repo status
```bash
fly ssh console -a leaflet-search-tap -C "wget -qO- http://localhost:2480/info/did:plc:abc123"
```

example: manually add a repo for backfill
```bash
fly ssh console -a leaflet-search-tap -C 'wget -qO- --post-data="{\"dids\":[\"did:plc:abc123\"]}" --header="Content-Type: application/json" http://localhost:2480/repos/add'
```

## fly.io deployment

both tap and backend should be in the same region for internal networking:

```bash
# check current regions
fly status -a leaflet-search-tap
fly status -a leaflet-search-backend

# restart tap if needed
fly machine restart -a leaflet-search-tap <machine-id>
```

note: changing `primary_region` in fly.toml only affects new machines. to move existing machines, clone to new region and destroy old one.

## references

- [tap source (bluesky-social/indigo)](https://github.com/bluesky-social/indigo/tree/main/cmd/tap)
- [ATProto firehose docs](https://atproto.com/specs/sync#firehose)
