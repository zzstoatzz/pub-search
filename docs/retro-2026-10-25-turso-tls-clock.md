# Turso ingestion stopped after certificate rotation

On October 25, 2026, Turso's newest document stopped at `07:08:04Z`.
Backend TLS failures began at `07:17:03Z`. Both Fly processes stayed running,
Jetstream events continued, and searches used the frozen replica. Snapshot
builds completed successfully against stale Turso data.

Zig 0.17's `std.http.Client` saves the certificate-validation time in `now`
when it first scans the trust store. The app started October 24 and the worker
October 22. Turso's replacement certificate had `notBefore=2026-10-25T00:00Z`,
so both long-lived clients rejected it. OpenSSL authenticated a Turso read
from the same Fly machine. A real Zig request succeeded with the current
clock, failed with a clock predating the certificate, and succeeded again
after refreshing the validation time.

The Turso client now refreshes that time on a TLS initialization failure and
retries once. A reader/writer lock excludes clock updates from all active
handshakes while preserving concurrent requests. Certificate and hostname
verification stay enabled. Run the real TLS regression explicitly with:

```sh
cd backend
TURSO_TLS_TEST_URL=https://leaf-zzstoatzz.aws-us-east-1.turso.io/ zig build test
```

## Persistence and monitoring

The Jetstream handler previously advanced its cursor after dispatch even
when dispatch swallowed write errors. Failed upserts and deletes now stop
the consumer without advancing that cursor. Deliberately ignored records
still advance it. Publication side effects and delete operations propagate
errors. HTTP 200 responses containing Hrana statement failures also fail
persistence. Timestamp-to-sequence anchor failures retain the recovery
position rather than silently starting at the live tip. Exhausted archive
transport or decode failures also stop the consumer instead of skipping
unread data. Removing the custom error callback uses the SDK defaults:
archive failures propagate, while recoverable live errors reconnect normally.

`/health/freshness` now requires a recent successful Turso request as well as
cursor progress, and exposes `turso_reachable` and `turso_age_seconds`.
The fast Logfire persistence alert now covers database HTTP, server, and
pipeline failures plus failed Jetstream persistence. The obsolete alert for
`leaflet-search-ingester` is disabled; that app was deleted in August.

The watchdog's silence did not indicate recovery: it deduplicates emissions
for three hours, while its Logfire alert looks back only twenty minutes.
The six-hour freshness alert correctly remained active.

## Recovery

The bounded HTTP helper used a 250 ms completion poll. Production Turso
spans had a 250 ms minimum despite much faster network completion, making
serial replay pay that delay for every read and write. The poll is now
25 ms; the elapsed-clock deadline and joined cancellation are unchanged.

Back up the durable sequence cursor before rewinding. Pause the app process
while replacing its cursor so the running consumer cannot overwrite it,
then restart it.
A legacy microsecond timestamp before the failure is accepted at startup
and translated to an archive sequence, followed by the normal archive/live
cutover. For this recovery, authenticated archive metadata located segment
7569; its checksum-matched block index narrowed the replay floor to
`25540896952` (the next block starts at `06:59:53Z`), before both the last
known update and the first recorded TLS failure. Keep the worker at exactly one machine. Replayed writes are
idempotent; verify new Turso timestamps, overlay rows, stream progress,
and successful searches before removing temporary recovery files.

## Verification

- 190 backend tests passed locally, including the real TLS clock regression,
  failed-delete cursor preservation, rejected Hrana statements, and hung-request
  cancellation. Python checks passed: 67 tests and four subtests.
- [Production deployment](https://github.com/zzstoatzz/pub-search/actions/runs/40246455557)
  passed against `45b49eb`; both Fly process groups run that image.
- A document created at `08:51Z`, during the outage, was recovered and found
  through both the origin keyword API and the site's `/api/search` route.
- The persistence and six-hour freshness alerts cleared. Scheduled ingestion
  watchdog runs at `23:45Z` and `00:01Z` passed.

## Active-tail recovery bottleneck

The retained live tail exposed a separate Stream performance problem. Its
active-region cold reader restarts at the file header for each 1,024-row
batch (`stream/src/internal/storage/cold.zig`). Pub-search's cursor kept
advancing, but remained about twenty minutes behind the source. An independent
read-only WebSocket probe reproduced slow delivery from that cursor.

The upstream Go reader seeks to the containing flushed block through
`ActiveFlushedRange(startSeq)` (`internal/ingest/writer.go:741` and
`internal/subscribe/replay.go:264`, inspected at `289b032`). Stream's
`ColdSnapshot` currently carries the active length but no starting offset.
This is a port gap, not an inherent replay cost.

A dry run verified that a temporary `JETSTREAM_SUBSCRIBE_READ_BATCH=32768`
override preserves the running admitted image and all three production
Compose files. Applying and restoring it restarts shared Stream, affecting
its other listeners; approval was requested before that broader operation.
No Stream production setting was changed during diagnosis.

## Recovery completed

Pub-search caught up after the old active segment naturally rotated at
`2026-10-26T01:17Z`, before the Stream deployment. Stream's permanent block
seek fix, `3f7d356`, was subsequently admitted through all 21 suites and
deployed at `02:02:24Z`. It prevents the prefix-rescan bottleneck recurring
as the next active segment grows. A fixed-cursor production probe advanced
357,436 sequence positions in 25 seconds versus 1,925 before deployment;
an extended probe reached live traffic. Artifact binding, tests, deployment,
and replay evidence are retained in the relay repository at
`docs/incidents/2026-10-25-stream-active-replay/README.md`.

Final independent checks at `02:13–02:15Z` established:

- The pub-search cursor advanced from `25569377238` to `25569416670`,
  passing the earlier Stream head `25569381891`. The subsequently sampled
  head was `25569418409`, a gap of 1,739 sequence positions. These are
  non-atomic samples and are not an exact time-lag measurement.
- Turso contained 149,265 documents, with newest `indexed_at=02:11:08Z`.
  “Zen and the Art of Open Source Maintenance,” indexed at `02:09:06Z`,
  was present in Turso and returned by both origin and public site searches.
- Freshness health was green, the persistence, consumer, and watchdog alerts
  were clear, and there were no error-level backend records since `02:00Z`.
  The latest three scheduled ingestion watchdog runs passed.
- Both Fly machines were started at their original 1,024 MB, with exactly
  one app and one worker. The recovery cursor backups and local temporary
  scripts were removed after these checks; unrelated workspace files remain.

The health endpoint proves recent cursor progress and successful Turso
requests; it does not independently measure distance from the producer's
head. Recovery completion therefore used direct cursor/head comparison and
database/search checks. A separate search-latency alert reflected one
5.57-second request at `01:39Z`; all measured searches from `01:40Z` through
the final audit were below 1.34 seconds.
