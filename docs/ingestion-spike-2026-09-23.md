# September 23 ingestion spike

Investigated September 24 CDT (September 25 UTC) using the live dashboard,
Logfire, and read-only SQL against the serving machine's `/data/local.db`.

The dashboard showed 4,076 documents for September 23 UTC. Four authors
accounted for 3,674 (90.1%):

| Publication / author | Documents indexed that day | Evidence |
| --- | ---: | --- |
| jcrt.org | 1,675 | Publication dates 1999–2026; Logfire recorded 1,664 republish replacements, mostly 15:00–17:00 UTC. |
| dryan.com | 1,478 | Publication dates 2012–2026; indexed 04:22–05:41 UTC; Logfire also recorded 162 same-collection renames that day. |
| Sygnin (Leaflet) | 341 | Sample titles are sequential comic pages: `Chapter 1 - Cover`, `Chapter 1 - 001`, etc. |
| blog.localstack.cloud | 180 | Publication dates 2021–2026; Logfire recorded 178 republish replacements. |

The remaining 402 documents are comparable to nearby daily totals. This
supports archive import / republishing as the main explanation, rather than
thousands of freshly written posts. The exact upstream action that triggered
each batch was not established.

The dashboard groups current document rows by `indexed_at`, not first-ever
discovery or publication date. Same-URI unchanged content preserves that
timestamp, but changed content and replacement records can land in a new day.
The daily bar therefore must not be interpreted as net corpus growth.

Sources:

- Live `/api/dashboard` on `https://leaflet-search-backend.fly.dev`.
- [Logfire pub-search](https://logfire.pydantic.dev/waow/pub-search), September 23 UTC:
  `indexer: republish supersedes%` and `indexer: same-collection rename%` logs,
  grouped by DID extracted from the message.
- Read-only serving SQL: group `documents` by `did, platform` where
  `indexed_at >= '2026-09-23' AND indexed_at < '2026-09-24'`; resolve publications
  through `publications.did`.
- `backend/src/server/dashboard.zig` timeline query and
  `backend/src/ingest/indexer.zig` document upsert timestamp policy.
