# tap (firehose sync)

leaflet-search uses [TAP](https://github.com/bluesky-social/indigo/tree/main/cmd/tap) from bluesky-social/indigo to receive real-time events from the ATProto firehose.

## what is tap?

tap subscribes to the ATProto firehose, filters for specific collections (e.g., `pub.leaflet.document`), and broadcasts matching events to websocket clients. it also does initial crawling/backfilling of existing records.

key behavior: **TAP only broadcasts live firehose events, not resynced historical data**. the resyncer marks records as `Live: false` and does not pass them to the websocket outbox. this means the backend only receives new/updated records after TAP starts - historical data must be fetched separately.

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

2. **resynced records don't broadcast** - TAP's resyncer fetches historical data but marks it `Live: false` and doesn't send it to websocket clients. only live firehose events are broadcast.

3. **silent extraction failures** - if using zat's `extractAt`, enable debug logging to see why parsing fails:
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
| document count not increasing | TAP only sends live events, not historical | this is expected behavior |

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
