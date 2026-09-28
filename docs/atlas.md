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

### ⚠️ the flow deploys data, NOT frontend changes

`flows/atlas.py:deploy_to_pages` calls `wrangler pages deploy` **directly** — it does not regenerate the workbox service worker. That's fine for `atlas.json`, which `workbox-config.cjs` serves via a `StaleWhileRevalidate` runtime cache rather than precaching. But `*.js` **is** precached with a content hash baked into `sw.js`, so:

- changed **`atlas.json` only** → the flow is sufficient
- changed **`atlas.js` / any `site/*.js`** → you must run `site/deploy.sh` (regenerates `sw.js`), or returning visitors keep the old script forever

`deploy.sh` ships whatever `site/atlas.json` is on disk, and that file is gitignored — so pull the live one down first or you'll overwrite good data with a stale local build:

```bash
curl -sfo site/atlas.json.gz https://pub-search.waow.tech/atlas.json.gz
cd site && ./deploy.sh
```

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

`/atlas-summary-preview` is a separate reading page; the map does not load summary
code or data. `scripts/build-atlas` runs `atlas_summaries.write_preview` after
writing its normal gzip, so the existing six-hour Prefect flow generates and
publishes summaries with the dataset. No flow registration change is needed.

The first preview covers the 12 largest fine clusters. Each uses up to 10 actual
members, ordered by membership strength with at most two per author before
filling remaining slots. The document API supplies policy-filtered extracted
text; only the first 3,000 characters of each sampled document go to
the model, with identical excerpts deduplicated. The model is
`claude-haiku-4-5`, using the same Anthropic credential as label generation.
At least three readable documents are required. These are explicitly sample
summaries, not independently evaluated descriptions of the entire cluster.

`atlas-summaries.json` is an optional, gitignored sidecar. It records the exact
Atlas content hash, membership hash, sampled source URIs, cited sources, model,
and generation time. The preview verifies the dataset hash and source membership
before displaying anything. It fetches both files without runtime-cache reuse;
a deployment race or stale pair produces a retry message rather than attaching
an old summary to a new cluster ID. Existing Atlas consumers remain unchanged.

Generation uses at most three concurrent requests. Previously deployed summaries
are reusable only when membership, sampled text, prompt, and model match. Missing
credentials, unreadable documents, and model failures leave an unavailable or
partial preview and do not block the map rebuild. The sidecar is always rewritten
so an unsuccessful run cannot accidentally publish an old preview as current.

For a standalone refresh using the flow's injected environment:

```sh
uv run scripts/atlas_summaries.py site/atlas.json.gz --limit 12
```

Checks: `uv run --script scripts/tests/test_atlas_summaries.py` and
`node --test scripts/tests/atlas-summaries.mjs`. Tests cover missing credentials,
legacy datasets, stale preview replacement, author diversity, source references,
and rejection of stale or invalid membership in the browser contract.
