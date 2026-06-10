# Prefect rebuild-atlas OOM report - 2026-06-05

## Summary

The `my-prefect-server` deployment `rebuild-atlas/rebuild-atlas` crashed on the
scheduled run `rebuild-atlas-9f0c8f46` because the atlas build process triggered
global node OOM on the single-node k3s cluster.

This report is intentionally left in the `leaflet-search` repository because
the memory-heavy code path lives in `scripts/build-atlas`.

## Observed failure

- Flow run: `rebuild-atlas-9f0c8f46`
- Flow run id: `9f0c8f46-1ecc-4f1f-bd13-e91669a5fdde`
- Kubernetes job: `rebuild-atlas-9f0c8f46-ft5sn`
- Started: `2026-06-05T18:00:19Z`
- Crashed: `2026-06-05T18:05:50Z`
- Prefect observer logged OOMKilled at `2026-06-05T18:05:48Z` and again at
  `2026-06-05T18:10:50Z`.

The node journal showed a global OOM event at `2026-06-05T18:05:46Z`. The OOM
victim was a Python process inside the rebuild-atlas pod with approximately
`2.3 GiB` anonymous RSS. Because the pod had no memory request or limit at the
time, it ran as Kubernetes BestEffort and the kernel performed global OOM
selection.

Cluster-side guardrails have since been added in `my-prefect-server` so future
flow jobs get explicit memory requests/limits and accidental BestEffort pods
receive namespace defaults. This should contain a runaway job inside its own
cgroup, but it does not explain or fix the build script's memory footprint.

## Suspect code path

`scripts/build-atlas` currently:

1. Exports all vector rows from Turbopuffer into `rows`.
2. Copies vector attributes into a second Python list, `vectors`.
3. Converts that list to dense `np.float32` matrix `X`.
4. Runs PCA, UMAP, and HDBSCAN while the original row/vector Python objects are
   still retained.
5. Builds `points`, `clusters`, and `publications`, then serializes the full
   output JSON.

Even with `np.float32`, the peak memory is not just the final vector matrix. It
includes the original JSON response/list objects, duplicated vector lists,
NumPy arrays, PCA/UMAP/HDBSCAN intermediates, title metadata, cluster label
structures, avatar/publication structures, and final JSON assembly.

## Recommended fixes to consider

- Do not retain `rows` and `vectors` after constructing `X` and `metadata`.
  Explicitly `del rows, vectors` before PCA/UMAP.
- Build the NumPy matrix more directly during export if possible, avoiding the
  second full list of Python vector objects.
- Add memory checkpoints around export, `np.array`, PCA, UMAP, HDBSCAN, label
  refinement, avatar resolution, and JSON serialization. Log RSS so the next
  run identifies the real peak.
- Consider a configurable max document/vector count or sampling mode for the
  atlas if the corpus has grown substantially beyond the documented `~12k`
  vectors.
- Consider bounding BLAS/Numba thread counts in the flow environment if UMAP or
  HDBSCAN is spawning memory-amplifying worker threads.
- Stream or incrementally assemble output if JSON serialization becomes part of
  the peak.

## Reproduction notes

The failed run did not persist the Kubernetes pod long enough for postmortem
`kubectl describe pod` inspection because finished job TTL is five minutes.
The durable sources were Prefect logs and the node journal.
