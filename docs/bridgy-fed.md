# bridgy fed

[Bridgy Fed](https://fed.brid.gy) bridges content from the fediverse (Mastodon, etc.) into ATProto. these documents show up with `platform='other'` because they use `site.standard.*` collections but aren't hosted on any known publishing platform.

## why we exclude it

we've tried including bridgy fed content twice. both times it caused problems:

**attempt 1 (early 2026):** bridgy fed content flooded the index — tens of thousands of short fediverse posts mixed in with long-form articles. search results became polluted with content that wasn't meaningfully "published" in the way leaflet/whitewind/etc. content is. we added `is_bridgyfed` column to turso and marked all bridgy fed documents, then excluded them from search results.

**attempt 2 (later):** even with search exclusion, the vectors remained in turbopuffer and polluted semantic search and the atlas visualization. had to run `scripts/purge-bridgyfed-vectors` to clean up ~26k orphan vectors.

**current state:** bridgy fed content is now **dropped at ingest** in the backend. the tap still receives it (can't filter at the firehose level), but the backend's ingest pipeline checks the PDS endpoint and silently drops any DID hosted on `brid.gy`. this is the cleanest solution — no storage, no cleanup needed.

## detection

a DID is bridgy fed if its PDS endpoint (via `plc.directory` resolution) contains `brid.gy`. the scripts resolve this by:

1. query turso for distinct DIDs with `platform='other'`
2. resolve each DID's PDS via `https://plc.directory/{did}`
3. check if `service[type=AtprotoPersonalDataServer].serviceEndpoint` contains `brid.gy`

## scripts

- `scripts/mark-bridgyfed` — marks existing bridgy fed rows in turso (`is_bridgyfed = 1`). dry run by default, `--apply` to update.
- `scripts/purge-bridgyfed-vectors` — deletes bridgy fed vectors from turbopuffer. loops until all are removed (tpuf caps queries at 10k). dry run by default, `--apply` to delete.

both scripts use pydantic-settings with `.env` file (dotenv takes priority over environment variables).

## if we ever reconsider

the fundamental issue is that bridgy fed content is qualitatively different from native ATProto publishing — it's short social media posts, not articles/essays. if bridgy fed ever supports long-form content or we want to include fediverse posts, we'd need:

1. content-length filtering (min word count or similar)
2. a separate `platform='fediverse'` designation so users can filter
3. careful testing of search result quality before and after
