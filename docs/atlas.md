# atlas

2D semantic map of the document index. each document is a point on a canvas, positioned by semantic similarity and colored by platform.

**live:** [pub-search.waow.tech/atlas](https://pub-search.waow.tech/atlas)

## data pipeline

`scripts/build-atlas` is a batch python script (uv inline dependencies) that:

1. **exports vectors** from turbopuffer — paginated query with `rank_by: ["id", "asc"]`, fetches all ~12k vectors + metadata
2. **PCA 1024 → 50** — denoising pass, typically captures ~60% variance
3. **UMAP 50 → 2** — cosine metric, `n_neighbors=15`, `min_dist=0.1`, `random_state=42`
4. **HDBSCAN** at two granularities on the 2D coordinates:
   - coarse: `min_cluster_size=100` (~30 clusters, zoomed-out labels)
   - fine: `min_cluster_size=20` (~160 clusters, zoomed-in labels)
   - outliers assigned to nearest cluster centroid
5. **c-TF-IDF** on document titles per cluster → 3-term labels
6. **outputs** `site/atlas.json` (~3MB, gitignored)

run time: ~20s. dependencies: `umap-learn`, `hdbscan`, `scikit-learn`, `httpx`, `numpy`, `pydantic-settings`.

```bash
./scripts/build-atlas              # writes site/atlas.json
./scripts/build-atlas -o out.json  # custom output path
```

## frontend

`site/atlas.html` + `site/atlas.js` + `site/atlas.css`

- **canvas 2D** renderer — no libraries, sprite-based (pre-rendered offscreen canvas per platform)
- **pan/zoom** via wheel, drag, touch/pinch (max 15×)
- **semantic zoom**: coarse labels → fine labels → document titles as you zoom in
- **hover tooltip** with title, author, platform
- **click** opens document URL
- **theme support**: dark (default), light, system — synced with the rest of the site

## recomputing

the atlas is a point-in-time snapshot. rerun the build script when the index changes meaningfully:

```bash
./scripts/build-atlas
cd site && wrangler pages deploy . --project-name leaflet-search
```

not yet automated — could be a GitHub Action or post-backfill hook.

## future work

- **hierarchical clustering**: replace the two-strata (coarse/fine) approach with a proper hierarchy (Ward linkage on HDBSCAN centroids + `cut_tree` at multiple levels) for smooth fractal zoom
- **LLM-generated labels**: use Claude Haiku to produce coherent cluster names instead of c-TF-IDF keyword soup
- **auto-update**: trigger rebuild after significant index changes
