# retrospective: the hourly snapshot builder hung for eleven hours (2026-07-15 -> 07-16)

## what happened

Pub-search served the same keyword snapshot for **11h 42m**. The last healthy
build, `b1784132043-c308`, started at 16:14 UTC with a 16:13 source watermark and
remained live until 03:56 UTC the next day. During that window the API stayed up
and returned successful responses, but the derived index stopped advancing.
The replacement snapshot contained 373 more documents, 13 more publications,
586 more tags, and 27 more recommendations than the stale one.

The next hourly builder run started normally at 17:14, loaded the corpus, and
reported 47,601 built documents at 17:29. Its next operation was the Turso row-
count verification gate. The request write succeeded, but the process then
waited forever for response bytes on a pooled TCP connection. Zig 0.16's HTTP
client has no read timeout. The process therefore neither completed nor failed,
Fly's `on-failure` restart policy had no event to react to, and the singleton
scheduled Machine could not begin another hourly run while it remained alive.

This was not an unforeseen failure class. The June 10 retro explicitly says a
pooled Turso connection can hang forever after the far side silently closes it
and lists socket deadlines as unfinished work. We subsequently productized the
hourly builder without a wall-clock deadline or external run supervisor. The
incident is the predictable result of leaving that known failure uncontained.

Serving availability and data integrity were preserved by the snapshot design:
the previous verified artifact remained live and no partial build was promoted.
Freshness was not preserved. For a search system, returning a healthy `200`
from an index that silently stopped advancing is a production incident.

## impact

- **Freshness:** one snapshot served for 11h 42m. This exceeded the documented
  roughly 75-minute hands-off bound by about 10h 27m.
- **Affected surfaces:** keyword search and replica-backed publication, tag,
  recommendation, and display data did not include changes after the 16:13 UTC
  watermark.
- **Availability:** the serving API remained available throughout.
- **Integrity and loss:** no source data was lost and no incomplete artifact was
  adopted. Turso continued ingesting; the derived snapshot was stale.
- **Observed delta at recovery:** 47,595 -> 47,968 documents, 7,624 -> 7,637
  publications, 82,094 -> 82,680 tags, and 4,373 -> 4,400 recommendations.

## timeline (UTC)

| time | event |
|---|---|
| 2026-07-15 16:14 | Healthy hourly build `b1784132043-c308` starts. |
| 16:37 | Build publishes successfully with source watermark 16:13:16; serving adopts it. R2 emits transient `501 Not Implemented` errors, but rclone retries succeed. |
| 17:14 | Next scheduled run starts on builder Machine `e823011c5d36e8`. The Machine is still pinned to a June 12 image, despite newer backend deploys. |
| 17:29 | Builder logs `built 47601 docs`; it then enters the Turso count gate and produces no more build progress. |
| ~19:40 | The watchdog reports the serving snapshot as 206 minutes old in a Bluesky mention. The alert detects staleness but does not wake a responder or remediate it. |
| ~23:05 | The watchdog reports the same build as 411 minutes old after its three-hour deduplication window. |
| 17:14 -> 03:21 | The same Fly Machine remains `started`. Hourly scheduling does not launch overlapping runs, so no later build gets a chance to recover independently. |
| 2026-07-16 03:18 | Active investigation reaches the builder. SSH inspection confirms the process is alive with low RSS and blocked in kernel `tcp_recvmsg`, waiting for a network read. |
| 03:21 | Stuck builder is stopped manually. |
| 03:21 -> 03:30 | Recovery image is prepared. The first build fails because `zqlite` was sourced from mutable GitHub `master`; upstream moved while the manifest hash remained pinned. The URL is pinned to commit `5ac4cabe...`, whose content matches the existing hash. |
| 03:30 | Builder Machine is updated to the new image and explicitly started with `TURSO_DISABLE_KEEPALIVE=1` and a 2,700-second builder deadline. |
| 03:40 | Replacement run finishes loading 47,968 documents and passes the Turso count gate that hung previously. |
| 03:49 | SQLite compaction, integrity check, and sha256 complete. |
| 03:51 | Build `b1784172644-6fdb` publishes successfully after transient R2 `501` retries; builder exits 0 and the scheduled Machine stops normally. |
| 03:56 | Promote watcher stages the artifact, restarts serving, and adopts it. `/snapshot`, `/stats`, and live keyword search return healthy bodies from the new build. |

## root causes

### 1. An unbounded remote read in a batch process

The builder reused the process-wide Turso HTTP client's pooled connections.
After `sync.buildSnapshot` completed, the doc-count gate issued another Turso
query. The local write was accepted, but no response arrived. Zig's HTTP client
has no read deadline, so the thread remained in `tcp_recvmsg` indefinitely.

The July 7 `fetchEvictRetry` fix (`7a5efff`) handles a related but narrower
failure: `WriteFailed` or `HttpConnectionClosing` while sending on a stale
pooled connection. It cannot help when the send appears successful and the read
never completes. The stuck builder was on an older image anyway, but updating it
to July 7 code alone would not have prevented this incident.

The immediate mitigation disables connection reuse only for the batch builder.
That makes each request use a fresh connection, avoiding the poisoned pooled-
socket path without changing latency-sensitive serving behavior. The builder
also now has a 45-minute wall-clock watchdog that exits nonzero so Fly can retry.

### 2. The scheduler was mistaken for a supervisor

There was one persistent Fly Machine with `schedule = "hourly"` and restart
policy `on-failure`. Those settings provide cadence and react to process exit;
they do **not** enforce maximum runtime. A live, hung process satisfies both
systems indefinitely. Because the scheduled unit is a singleton Machine, the
next hour does not create an independent attempt.

We had no invariant saying "a builder run must terminate within N minutes" and
no external controller enforcing it. The process watchdog now bounds the common
case, but an external reconciler is still needed because a process cannot be its
own final authority when the whole VM or runtime is unhealthy.

### 3. Builder deployment was a manual, drifting side channel

Backend deploys update the serving Machine only. The scheduled builder pins the
image it was created with and had remained on a June 12 image for 33 days. The
run exposed this directly: old logs invoked `./leaflet-search`, while the current
image invokes `./pub-search`.

This behavior was documented in `snapshot-pipeline.md` as a manual
"recreate the scheduled builder machine" step for policy changes. Documentation
did not make the operational dependency safe. A production component that runs
the same binary against the same schema must be advanced by the deployment, or
continuously reconciled to the intended image. Manual recreation guaranteed
eventual drift.

The stale image was not the direct cause of the successful-write/read-hang --
current code still lacked read deadlines -- but it removed newer diagnostics and
fixes from the only component responsible for snapshot freshness.

### 4. Detection existed; bounded recovery did not

The watchdog correctly checked the live `/snapshot` manifest rather than API
availability and began alerting after three hours. That is better than silent
failure, but it had three material gaps:

1. Three hours is two missed hourly cycles before first detection, well beyond
   the documented 75-minute freshness bound.
2. A Bluesky mention is a report, not paging. It did not reliably wake a human.
3. Detection had no remediation. It could describe "builder or promote watcher
   stalled" but could not distinguish them, terminate an overlong run, or launch
   a replacement.

The pipeline therefore detected an already-unacceptable state and continued to
serve it for hours.

## contributing factors

### A known recurrence was accepted as "rare"

The June 10 retro's honest list says poisoned-socket hangs "will recur unless
the scheduled work lands." The snapshot pipeline then moved Turso work off the
serving box, which correctly contained availability impact, but containment was
treated as resolution. Moving a known unbounded wait into a batch job changes a
full outage into stale data; it does not make the wait acceptable.

### The artifact build was not reproducible

`zqlite` used a mutable `master.tar.gz` URL with an immutable Zig content hash.
When upstream changed, recovery builds failed with a hash mismatch. The hash did
its safety job, but the mutable source made a known-good revision impossible to
fetch until we reconstructed the matching commit. This added delay during an
incident and could have blocked a cold rebuild entirely.

### R2 emits repeated transient errors

Successful builds, including the recovery build, log `501 Not Implemented`
during R2 uploads before rclone retries succeed. This did not cause the stale
snapshot, but routine successful runs should not contain alarming transport
errors. They make the actual terminal failure harder to see and leave little
margin if retries stop succeeding.

### The builder had weak provenance

Published manifests reported `builder_version: "dev"`, so `/snapshot` could not
identify the source revision that produced the live artifact. Machine image
inspection was required to establish drift.

## what went well

- Snapshot isolation did exactly what it was designed to do: serving remained
  available and retained the last verified artifact.
- The freshness watchdog measured the derived data users actually receive. It
  detected a failure that ordinary health checks could not.
- Builder logs narrowed the stall to the boundary immediately after corpus
  construction; kernel state then confirmed a network read wait.
- The replacement build passed all verification gates, published pointer-last,
  and was adopted atomically.
- Recovery changed only the builder Machine. The serving Machine was not exposed
  to the experimental Turso connection setting.
- All 101 backend tests passed, and post-adoption `/snapshot`, `/stats`, and a
  real keyword query returned valid bodies.

## what went wrong in the response

1. **We did not begin with the production control plane.** The initial response
   claimed the coding shell's outbound network was restricted instead of simply
   running `fly`. That was false in practice and delayed the useful
   investigation. For a Fly alert, inspect Fly state first.
2. **The alert was initially discussed as a generic stale-snapshot report.** We
   should have immediately separated the three stages: builder, R2 pointer, and
   promote watcher. `/snapshot` plus builder and serving Machine logs identify
   the failed stage quickly.
3. **Recovery depended on an untested image build path.** The mutable `zqlite`
   URL failed only when we needed an emergency image. Production artifacts must
   be reproducible before an incident.
4. **We had to reconstruct builder ownership manually.** CI deploys serving,
   docs describe separate builder surgery, and the manifest says `dev`. There
   was no one command or dashboard showing intended image, running image, last
   successful run, current phase, and deadline.
5. **We declared architecture properties more strongly than operations earned.**
   `snapshot-pipeline.md` says a dead builder "stalls freshness loudly" and
   marks hourly offline builds as done. Loud after three hours is not bounded,
   and a pipeline without automatic restart is not operationally complete.

## action items

### shipped during recovery

- [x] Stop the hung builder and publish/adopt `b1784172644-6fdb`.
- [x] Add a default 45-minute builder wall-clock watchdog; configure the Fly
      Machine with `BUILDER_TIMEOUT_SECS=2700` and `on-failure` retries.
- [x] Add builder-only `TURSO_DISABLE_KEEPALIVE=1` so batch verification does
      not reuse pooled Turso connections.
- [x] Update the scheduled builder to the recovery image while preserving its
      hourly schedule, 1 GB size, production channel, and retry policy.
- [x] Pin `zqlite` to immutable commit `5ac4cabe...` with the existing verified
      content hash.
- [x] Verify 100/100 backend tests and live snapshot, stats, and keyword search.

### immediate: make the recovery durable

- [x] Commit and deploy the watchdog, builder-only connection policy, and
      immutable dependency pin.
- [x] Make backend deployment update the scheduled builder to the same immutable
      image digest. Remove the manual builder-recreation step as normal policy.
- [x] Set `BUILDER_VERSION` to the source commit and expose the builder image or
      revision in the manifest and operational telemetry.
- [x] Add `.dockerignore` for `.zig-cache`, `zig-out`, and `zig-pkg`; the
      emergency build warned about a 6.4 GB context.

### immediate: bound and page freshness failures

- [x] Lower snapshot-age paging to a threshold derived from actual runtime and
      cadence (initial target: 120 minutes, not 180).
- [ ] Route freshness failure to an interruptive channel with ownership and
      acknowledgement. Keep Bluesky as a public/status signal, not the only page.
- [x] Emit builder run telemetry with build ID, image revision, phase, elapsed
      time, last progress time, and terminal status.
- [x] Add an external guardian: stop a builder that exceeds 50 minutes and start
      a clean run when snapshot age exceeds 90 minutes.
- [ ] Escalate the promote watcher separately when a successful publication is
      not adopted within its expected polling and download window.

### follow-up engineering

- [ ] Add a true network read deadline to the Turso client when Zig exposes one,
      or own the socket/request layer needed to enforce it. Keep the process
      deadline even after request deadlines exist.
- [ ] Exercise the timeout path in an integration test using a server that
      accepts a request and never responds. The existing stale-connection test
      covers send failure, not this incident's read hang.
- [x] Replace Debian's `rclone v1.60.1-DEV` with pinned `v1.74.4`; one complete
      production upload then succeeded without the prior routine R2 `501`
      retries. Continue alerting when any upload exhausts retries.
- [ ] Add an end-to-end freshness canary: insert or identify a recent document,
      require it in the next eligible snapshot, and verify that serving adopted
      that exact build within the freshness objective.
- [ ] Test scheduled-builder failover by deliberately hanging a canary run and
      proving automatic termination, retry, publication, and adoption.

## follow-up verification (2026-07-16 UTC)

- Commit `deeb276` was deployed from an immutable image. Serving and builder
  were verified on digest `sha256:69a03e...`, with the builder stopped, hourly,
  and configured for a 2,700-second process deadline and fresh Turso connections.
- A disposable Fly canary ran the production builder image with a five-second
  deadline. It logged the armed watchdog, terminated nonzero at the deadline,
  and was removed without publishing.
- The external guardian was forced through its recovery path. It started the
  stopped production builder and verified the Machine reached `started`.
- Production build `b1784178587-70d8` processed 47,985 documents. The formerly
  hanging `verify_remote` phase completed in 29 seconds, compaction and upload
  completed, and the builder exited 0 after 1,168 seconds with no OOM.
- All three R2 writes succeeded without a visible `501` retry under pinned
  `rclone v1.74.4`. The promote watcher detected the build, staged it, restarted
  serving, and `/snapshot` reported the exact build and source revision.
- The full smoke suite passed after adoption and again after the automated
  deployment: keyword, semantic, hybrid, dashboard, timeline, latency,
  activity, stats, tags, and popular endpoints.
- The first GitHub deployment exposed a Linux-only test teardown hang: closing
  a listener did not wake a thread blocked in `accept`. The original code timed
  out in a Linux container; an explicit loopback wake completed 101/101 tests.
  Commit `9134072` then passed Linux CI, deployed, and reconciled the builder to
  the serving digest `sha256:e6384f...` in one successful 5m12s workflow.

## operating rules going forward

1. **Every recurring batch run has a maximum runtime enforced both inside and
   outside the process.** A schedule is not a supervisor and a restart policy is
   not a timeout.
2. **A freshness alert must fire before the freshness objective is breached and
   must wake an owner.** A public post alone is not paging.
3. **All production roles advance from one deployment artifact.** If a role is
   intentionally pinned, drift is continuously visible and reconciled.
4. **Known unbounded waits remain incidents-in-waiting until they are bounded.**
   Moving them off the serving box contains blast radius; it does not close the
   defect.
5. **Derived-data health is availability.** A search API returning `200` from an
   index that stopped advancing is degraded, even when source ingestion is fine.

## related documents

- [the snapshot pipeline](snapshot-pipeline.md)
- [the cutover cascade](retro-2026-06-10-cutover-cascade.md)
- [scaling plan](scaling-plan.md)
- Typeahead: [ingester wedge and recovery](../../typeahead/docs/retros/2026-06-12-ingester-wedge-and-recovery.md)
