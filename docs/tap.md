# tap (firehose sync)

leaflet-search uses [TAP](https://github.com/bluesky-social/indigo/tree/main/cmd/tap) from bluesky-social/indigo to receive real-time events from the ATProto firehose.

## what is tap?

tap subscribes to the ATProto firehose, filters for specific collections (e.g., `pub.leaflet.document`), and broadcasts matching events to websocket clients. it also does initial crawling/backfilling of existing records.

key behavior: **TAP backfills historical data when repos are added**. when a repo is added to tracking:
1. TAP fetches the full repo from the account's PDS using `com.atproto.sync.getRepo`
2. live firehose events during backfill are buffered in memory
3. historical events (marked `live: false`) are delivered first
4. after historical events complete, buffered live events are released
5. subsequent firehose events arrive immediately marked as `live: true`

TAP enforces strict per-repo ordering - live events are synchronization barriers that require all prior events to complete first.

## message format

TAP sends JSON messages over websocket. record events look like:

```json
{
  "type": "record",
  "record": {
    "live": true,
    "did": "did:plc:abc123...",
    "rev": "3mbspmpaidl2a",
    "collection": "pub.leaflet.document",
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
| collection | string | e.g., "pub.leaflet.document" | lexicon collection |

## gotchas

1. **action is a string, not an enum** - TAP sends `"action": "create"` as a JSON string. if your parser expects an enum type, extraction will silently fail. use string comparison.

2. **collection filters apply to output** - `TAP_COLLECTION_FILTERS` controls which records TAP sends to clients. records from other collections are fetched but not forwarded.

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

## debugging

### check tap connection
```bash
fly logs -a leaflet-search-tap --no-tail | tail -30
```

look for:
- `"connected to firehose"` - successfully connected to bsky relay
- `"websocket connected"` - backend connected to TAP
- `"dialing failed"` / `"i/o timeout"` - network issues

### check backend is receiving
```bash
fly logs -a leaflet-search-backend --no-tail | grep -E "(tap|indexed)"
```

look for:
- `tap connected!` - connected to TAP
- `tap: msg_type=record` - receiving messages
- `indexed document:` - successfully processing

### common issues

| symptom | cause | fix |
|---------|-------|-----|
| `websocket handshake failed: error.Timeout` | TAP not running or network issue | restart TAP, check regions match |
| `dialing failed: lookup ... i/o timeout` | DNS issues reaching bsky relay | restart TAP, transient network issue |
| messages received but not indexed | extraction failing (type mismatch) | enable zat debug logging, check field types |
| repo shows `records: 0` after adding | resync failed or collection not in filters | check TAP logs for resync errors, verify `TAP_COLLECTION_FILTERS` |
| new platform records not appearing | platform's collection not in `TAP_COLLECTION_FILTERS` | add collection to filters, restart TAP |

## TAP API endpoints

TAP exposes HTTP endpoints for monitoring and control:

| endpoint | description |
|----------|-------------|
| `/health` | health check |
| `/stats/repo-count` | number of tracked repos |
| `/stats/record-count` | total records processed |
| `/stats/outbox-buffer` | events waiting to be sent |
| `/stats/resync-buffer` | DIDs waiting to be resynced |
| `/stats/cursors` | firehose cursor position |
| `/info/:did` | repo status: `{"did":"...","state":"active","records":N}` |
| `/repos/add` | POST with `{"dids":["did:plc:..."]}` to add repos |
| `/repos/remove` | POST with `{"dids":["did:plc:..."]}` to remove repos |

example: check repo status
```bash
fly ssh console -a leaflet-search-tap -C "curl -s localhost:2480/info/did:plc:abc123"
```

example: manually add a repo for backfill
```bash
fly ssh console -a leaflet-search-tap -C 'curl -X POST -H "Content-Type: application/json" -d "{\"dids\":[\"did:plc:abc123\"]}" localhost:2480/repos/add'
```

## fly.io deployment

both TAP and backend should be in the same region for internal networking:

```bash
# check current regions
fly status -a leaflet-search-tap
fly status -a leaflet-search-backend

# restart TAP if needed
fly machine restart -a leaflet-search-tap <machine-id>
```

note: changing `primary_region` in fly.toml only affects new machines. to move existing machines, clone to new region and destroy old one.

## references

- [TAP source (bluesky-social/indigo)](https://github.com/bluesky-social/indigo/tree/main/cmd/tap)
- [ATProto firehose docs](https://atproto.com/specs/sync#firehose)
