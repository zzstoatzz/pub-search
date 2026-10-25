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
unread data.

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
