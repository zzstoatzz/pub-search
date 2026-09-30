# atlas

2D semantic map of the document index. each document is a point on a canvas, positioned by semantic similarity and colored by platform.

**live:** [pub-search.waow.tech/atlas](https://pub-search.waow.tech/atlas)

## data pipeline

`scripts/build-atlas` is a batch python script (uv inline dependencies) that:

1. **exports vectors** from turbopuffer — paginated query with `rank_by: ["id", "asc"]`, 10k rows/page, fetches all vectors + metadata. the live counts are rendered in the atlas footer; don't hardcode them here.
2. **PCA 1024 → 50** — denoising pass (~50% variance explained at current corpus size)
3. **UMAP 50 → 2** — cosine metric, `n_neighbors=15`, `min_dist=0.1`, `random_state=42`; coords normalized to [-1, 1]. **display only.**
4. **UMAP 50 → 10** — a second, separate fit (`n_neighbors=30`, `min_dist=0`) used **only** for clustering
5. **HDBSCAN** at two granularities, fit on the **10D** space:
   - coarse: `min_cluster_size=50`, `min_samples=10` (zoomed-out "regions")
   - fine: `min_cluster_size=20`, `min_samples=3` (zoomed-in clusters)
   - both thresholds are absolute, not corpus-scaled — cluster granularity therefore drifts as the corpus grows
   - noise remains unassigned (`-1`) at each tier; 2D centroids use assigned documents only
   - each fine cluster has a majority-vote coarse association among assigned coarse members, or `null` when none exist; this is not a strict hierarchy

   > **why 10D and not the 2D coords** — clustering in the display projection turns UMAP's own artifacts (tearing, crowding) into cluster boundaries. Scored against PCA-50 cosine space, which neither projection was fit in, the old 2D clustering gave silhouette **+0.004 coarse / −0.067 fine** — the fine tier was structured *worse than chance*. The 10D space gives **+0.033 / +0.017**. `cluster_selection_method="leaf"` and a corpus-scaled `min_cluster_size` were tested at the same time and both made it worse at our thresholds; neither was adopted.
6. **labels** — c-TF-IDF over assigned document titles per cluster → 3-term keyword seed, then refined into 2-4 word topic names by `claude-haiku-4-5`. Unassigned titles never contribute. Empty-title groups keep a generic keyword fallback. Requires `ANTHROPIC_API_KEY`; without it the c-TF-IDF keywords ship as-is.
7. **publication centroids** — documents grouped by `basePath` (2+ docs), enriched from turso with name/coverImage, plus author avatars and leaflet theme colors. Both use on-disk caches in `site/` (`atlas-avatar-cache.json`, `atlas-theme-cache.json`) that deploy alongside `atlas.json` — the prefect flow clones fresh each run, so the deployed copy is what it reads on cold start.
8. **outputs** `site/atlas.json.gz` (gzipped since 2026-08-25; the raw json crossed cloudflare pages' 25 MiB per-file limit at ~83k docs. `atlas.js` decompresses via `DecompressionStream`)

dependencies: `umap-learn`, `hdbscan`, `scikit-learn`, `httpx`, `numpy`, `pydantic-settings`, `anthropic`. Pinned to `numpy<2.2` and python `>=3.12,<3.14` — umap's transitive numba/llvmlite have no wheels outside that window.

```bash
./scripts/build-atlas              # writes site/atlas.json
./scripts/build-atlas -o out.json  # custom output path
```

## frontend

`site/atlas.html` + `site/atlas.js` + `site/atlas-gl.js` + `site/atlas-interaction.js` + `site/atlas.css`

- **WebGL** points, static connection buffers, and rotating planets; canvas 2D for nebulae/labels, with a sprite fallback when WebGL is unavailable
- **pan/zoom** via wheel, drag, touch/pinch (max 500×; documents become rotating planets past ~45×, then flat cards)
- **semantic zoom**: coarse labels → fine labels → document titles as you zoom in
- **cluster nebulae as lanterns**: one smooth-falloff glow per fine cluster at the weighted center of its members, sized by RMS spread with a bounded peak opacity — wide, translucent, and smooth at every zoom (coarse regions use the same sprite, fading out by ~2.8×)
- **label economy**: all text competes in one collision pass, placed in priority order — cluster labels (bold landmarks), then document titles ranked by real recommend counts (`/recommended` boost on `popScore`), then publication names with whatever room is left; per-layer caps live in `ATLAS_TUNE.labels`
- **hover/selection card** with title, publication, platform; **click** opens the document
- **theme support**: dark (default), light, system — synced with the rest of the site

### gesture recovery and visible planet work

The pointer controller introduced in `6acfcd1` (September 26) handles ordinary
pointer cancellation but could retain a pointer if its termination event was
missed. The regression sequence leaves one old pointer, starts a fresh primary
contact, and drags it: the old controller applies a 1.23× scale instead of a pan.
A new primary contact now clears old gesture state. Blur, page hiding, and the
end of all canvas touches also reset it; no-contact moves discard stale pointers.
Pointer termination is observed at the document so it still arrives if capture
is lost. Manual input stops automatic camera animation.

Planet candidates come from visible cells of the spatial index. Their positions,
radii, and opacity weights are retained while planets rotate, then recomputed
when the camera, viewport, geometry, or filters change. Other scene layers still
redraw during rotation; this is not a full renderer rewrite.

Run gesture regressions with `node scripts/tests/atlas-interaction.cjs`.
Serve the repository root with `python3 -m http.server 8789`, then open
`/scripts/tests/atlas-performance.html` and click **Run checks** for real-page
spatial selection and cache tests at phone and desktop dimensions. Selection is
compared with a full scan and brute-force nearest-neighbor spacing. Existing
`/scripts/tests/atlas-gl.html` checks actual GPU output. Native iOS Safari gesture
arbitration still needs a physical-device check.

[Jaz's Atlas](https://atlas.jazco.dev/) uses MapLibre vector tiles and zoom-gated
layers. The larger next step here is the geometry/metadata split below. Label
summaries are a separate design question: decide what evidence supports each
summary and where to reveal it without crowding the map or blocking interaction.

## recomputing

automated: the `leaflet-atlas` prefect deployment (`my-prefect-server/flows/atlas.py:rebuild_atlas`) runs **every 6 hours** on heavypad — clones the repo, runs `build-atlas`, runs `build-facts` (best-effort; a failure deploys the committed `facts.json` rather than blocking), and deploys `site/` to Cloudflare Pages. Pinned to python 3.13 and single-threaded BLAS/numba, since the build OOM'd the pod as the corpus grew.

trigger a rebuild now (against prefect-server.waow.tech, tailnet):

```bash
prefect deployment run 'leaflet-atlas/leaflet-atlas' --watch
```

### deploy consistency

`flows/atlas.py:deploy_to_pages` installs the site dependencies and regenerates
Workbox before deploying. Manual frontend releases still use `site/deploy.sh`.
The main gzipped map uses a network-first cache, with a ten-second timeout and
an offline fallback; auxiliary datasets retain stale-while-revalidate caching.
This prevents the usual old-map/new-summary pairing on return visits. If an
offline fallback or deployment race still produces a mismatch, the panel offers
**Reload map** instead of claiming generation is in progress.

Before a manual frontend deployment, fetch the live datasets, including the
summary sidecar, so the local checkout does not overwrite newer generated data.

## future work

- **membership contract**: `clusterCoarse` and `clusterFine` are actual HDBSCAN assignments, with `-1` meaning unassigned independently at each tier. `membershipProbabilityCoarse/Fine` preserve HDBSCAN's membership strength (not calibrated semantic correctness). `meta.membershipVersion=1` distinguishes this from older snapped datasets. Counts, centroids, glows, and connection lines exclude unassigned documents; those documents retain their positions, platform colors, searchability, and click targets. Fine-cluster `parent` is an association, not a guarantee that all members belong to that region.
- **why snapping was removed**: the initial April 2 implementation (`9c33eea`) assigned noise to the nearest centroid. The July 31 investigation (`e8075c0`) documented the purpose as coloring every point and measured weaker cluster separation after snapping; it fixed labels but left display and counts using artificial membership. The September correction removes that assignment entirely. Historical noise rates (~40%) should not be mistaken for measurements of the current build; current tier totals are emitted in `meta.nUnassignedCoarse/Fine`.
- **verification**: `uv run --script scripts/tests/test_atlas_membership.py` exercises real clustering, all-noise inputs, label evidence, and nullable parent associations. `uv run scripts/tests/serve-atlas-membership.py` serves a small dataset through the actual frontend; open its printed URL to verify unassigned points stay visible and receive no cluster connection lines.
- **exemplar-seeded labels**: feed the LLM the N documents nearest each centroid instead of c-TF-IDF keywords (sembleverse does this) — untested here
- **hierarchical clustering**: replace the two-strata (coarse/fine) approach with a proper hierarchy (Ward linkage on HDBSCAN centroids + `cut_tree` at multiple levels) for smooth fractal zoom
- **event-driven rebuild**: trigger off significant index changes instead of the fixed 6h cron

## payload scaling (measured 2026-08-25, 83,584 points)

the corpus has two counts: turso (`/api/api/dashboard` → `documents`, 102,513)
and the turbopuffer vector index (what the atlas exports, 83,584). the atlas
renders the vector index. the ~19k gap is unexplained — `embeddings` claims
102,513 and `bridgyfedDocuments` is 0 — and deserves its own investigation.

three formats, measured with `scripts/spike-columnar-atlas` on the live data:

| format | raw | gz | wall (25 MiB) hit at |
|---|---|---|---|
| v1 array-of-objects (current) | 25.3 MiB | 7.3 MiB | ~290k pts |
| v2 columnar + dictionaries | 12.6 MiB | 5.1 MiB | ~410k pts |
| v3 geometry only, binary quantized | 0.72 MiB (9 B/pt) | 0.46 MiB | ~2.9M pts |

design target is **10x the turso corpus (~1M points)**. v2 dies there
(~60 MiB gz), so v2 is not worth the migration. the architecture that
survives 10x splits the payload:

- **geometry.bin** — per point: x,y quantized to uint16 over [-1,1],
  platform u8, coarse+fine cluster u16. typed-array views, zero parse.
  8.6 MiB raw at 1M points; fits the per-file limit with ~3x to spare.
- **metadata** (title, uri parts, path) — never shipped up front. sharded by
  fine cluster or spatial tile, fetched on zoom/hover; search already goes
  through the API. 14.2 MiB raw today, ~140 MiB at 10x — fine when no single
  shard exceeds the limit and the initial load never includes it.
- clusters/publications stay as one small json (labels, centroids, pubs).

initial page load becomes ~constant in corpus size (geometry + labels),
which also fixes the client cost: today the browser parses 25 MiB of JSON
into 83k objects before first paint of the map.

at 1M points the *build* breaks before the payload does — UMAP on 1M×1024
and the single-pod export already OOM'd once at a tenth of that
(`prefect-rebuild-atlas-oom-2026-06-05.md`, `scaling-plan.md`). payload v3
and the builder move are separable; do not couple them.

## cluster summary preview

Atlas's **topics in view** control opens a list ranked by the number of actual
cluster members in the viewport, respecting platform filters. Counts update after
180 ms without view changes. The list includes every fine cluster in view, whether
or not a summary exists, with 20 rows at a time. Choosing a topic centers it and
keeps its members bright while softening other points. Selection stays fixed while
panning. Closing the panel clears that highlight.

Every visible region and cluster label is selectable and takes priority over
documents underneath. Overlapping touch padding picks the closer label. Region
documents use direct coarse membership; they do not roll up fine clusters. Document
cards link to their assigned fine cluster, with no invented link for unassigned
documents. The panel always lists actual documents, with summaries and source
excerpts when available. On phones it occupies at most 55% of the viewport. The old
`/atlas-summary-preview` URL redirects to `/atlas?topics=1`.

The six-hour Prefect flow builds the map, then runs `scripts/atlas_summaries.py`
as a separate step with a one-hour timeout. Summary failure does not block publishing.

Generation covers both coarse regions and fine clusters with at least three distinct readable member documents. Regions use direct coarse membership and coarse membership strength; they never roll up fine clusters.
Each starts with up to 10 actual members, ordered by membership strength with a stable URI
hash to break ties and at most two per author before filling remaining slots. The
document API supplies policy-filtered extracted text; the first 3,000 characters per
document go to `gpt-6-luna`, with identical excerpts deduplicated. The prompt asks for
two short sentences (30–45 words, at most 50) in direct language; coverage and AI
attribution appear in the sources disclosure. Both tiers use the same summary panel. These
summaries have not undergone independent quality evaluation.

`atlas-summaries.json` is an optional, gitignored sidecar containing membership
hashes, source URIs and excerpts, cited sources, model, and generation time. Atlas
loads it after the map and checks the build timestamp, exact member hashes, counts,
labels, and source membership. A mismatched sidecar offers a map reload. Missing generation, missing topic
summaries, and loading failures have distinct messages; retry performs a fresh
request even after a successful but partial response. In every case, the map continues working. It does not download the Atlas twice.

Generation uses at most six concurrent requests and the dedicated
`pub-search-atlas-openai-api-key` Prefect Secret, injected as `OPENAI_API_KEY`.
Document hydration is paced to one request per second, with bounded retries for
429 and transient gateway failures.
SOPS holds its canonical value under `prefect.blocks`; `pub_search_atlas.OPENAI_API_KEY`
references that block. Cached summaries require matching membership, text, label,
prompt, model, and retrieved context. The sidecar records actual input/output token usage and cache hits.
Failures leave an unavailable or partial sidecar and do not block the map rebuild.
The sidecar is always rewritten to prevent stale data from surviving a failed run.

Standalone refresh in the flow's injected environment:

```sh
uv run scripts/atlas_summaries.py site/atlas.json.gz
# Add --limit 4 for a bounded quality check; --limit 0 disables generation.
```

Checks: `uv run --script scripts/tests/test_atlas_summaries.py`,
`node --test scripts/tests/atlas-summaries.mjs`, and
`node scripts/tests/atlas-interaction.cjs`.

Atlas's summary release uses `?build=topics-5` on its CSS and map scripts, with
matching URLs in the Workbox manifest. When changing those assets, bump the build
value in both `atlas.html` and `workbox-config.cjs`, then regenerate `sw.js`.
The previous worker ignores `v` parameters; reusing that parameter can combine
new HTML with old cached code during an update.

Atlas HTML is excluded from precaching and uses network-first navigation with an
offline fallback. `sw-atlas-refresh.js` refreshes open Atlas tabs when a new worker
activates, so replacing the controller also replaces the page's old code and map.
The activation handler starts navigation without awaiting it: awaiting navigation
inside `activate.waitUntil` deadlocks because that navigation needs activation to
finish. Verified by upgrading a real worker while its cached old page stayed open.


Interaction regression: run `uv run scripts/tests/serve-atlas-membership.py` and
open `http://127.0.0.1:8794/topics` (also `?desktop=1`). This exercises the real
Atlas renderer and pointer handlers with a label over documents, no summaries,
and unassigned neighbors. Checks include label priority, nearby browsing, exact
highlight membership, stable selection during panning, and document-to-topic links.


### introduction and presentation changes

`71aa1b6` introduced an optional standalone preview on September 27, 2026.
`e258dd1` moved it into the map with concise text and a mobile bottom sheet.
`0fa89af` added asset-version URLs for service-worker upgrades; `4b15157`
made topics selectable regardless of summary availability, added nearby browsing
and document links, and kept source excerpts in a disclosure. `21c05a8` added
full coverage and caching, `09d8051` retried malformed output, `b8d6692` tightened
the copy, and `dd679d8` added direct coarse-region summaries.

The prompt now says the topic label appears immediately above the description,
so the opening should add detail rather than repeat the label. A validation check
retries openings that reuse a phrase from the heading, with corrective feedback. It asks for a
pattern shared by members, with citations confined to `sourceIds`.

### supplemental context

`scripts/atlas_context.py` uses the same Turbopuffer namespace and existing
Voyage document embeddings as search. It normalizes the sampled members' vectors
and queries their mean direction. Two candidate pools (12 each) cover the general
index and specifically nate's `notes.zzstoatzz.io` publication. Only documents not already read
with cosine similarity >= 0.75 are eligible; at most three survive deduplication.
This is a conservative initial threshold, not a calibrated relevance probability.
A top-K result alone is never sufficient, and no matches is an expected outcome.

PubSearch's `/document` supplies the excerpts and enforces serving policy.
The notes repository's Markdown is available through its published standard.site
records, so retrieval does not require a separate repository index. Discovery
opt-in, including member hydration, is limited to the notes author's DID and
notes host; other publications retain normal visibility filtering.

Context is optional: missing vector credentials or failed retrieval leaves a
member-only summary and records `contextStatus`. The prompt restricts context
to clarifying ideas already supported by members. Retrieved member documents retain `role: member`; outside
sources carry `role: context`. Both record `cosineSimilarity`; the panel labels them as related context
and excludes them from member coverage. At least three member excerpts and a
member citation are still required. Cache identity includes the retrieved text.
The sidecar stores the prompt, threshold, excerpts, scores, model, and requested
levels/limits for analysis.

### snapshot history

`scripts/atlas_history.py` saves immutable map/summary pairs in SQLite. SHA-256
addresses gzip-compressed objects; repeated archives reuse objects and snapshots.
The `snapshots` table indexes timestamps, status, counts, and both object hashes.
Restore checks both hashes before writing to a fresh output directory.

The Prefect flow archives every completed map before publishing, including maps
with missing or unavailable summaries. Archive failure prevents publication.
On heavypad the database is
`/home/stoat/prefect-analytics/pub-search-atlas/history.sqlite3`, outside the
flow's temporary clone. This is durable host storage, not an off-host backup.
History starts when the updated flow is released; earlier overwritten sidecars
cannot be reconstructed from the current site.

```sh
python scripts/atlas_history.py /path/to/history.sqlite3 save site/atlas.json.gz
sqlite3 /path/to/history.sqlite3 'select id, atlas_generated_at, status from snapshots order by archived_at desc'
python scripts/atlas_history.py /path/to/history.sqlite3 restore SNAPSHOT_ID /tmp/atlas-replay
```

The browser recovery regression is at `/summary-states` on the membership test
server. It exercises real HTTP failure, unavailable generation, a partial
successful response, and recovery to a summary with separately labeled context.

### Cloudflare CLI

The installed `cf` CLI can inspect Pages deployments:

```sh
cf cli search "list Pages project deployments"
cf pages projects deployments list --project-name leaflet-search --env production --per-page 3
```

It accepts `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN`; use the existing
Pages deployment credential. In `cf` v1.0.0-beta.5, `cf pages deploy` is a stub
that explicitly rejects legacy Pages projects and directs them to Wrangler.
Keep `site/deploy.sh` for this project's uploads and service-worker regeneration.
`cf deploy` targets Pages on Workers and is not a drop-in replacement here.
