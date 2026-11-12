# deployment

Backend changes under `backend/**` deploy through GitHub Actions on main. Push
both Tangled origin and the GitHub mirror. Run Fly commands from `backend/`:
`--app` changes the destination name but still reads config from the current directory.

## frontend

`site/deploy.sh` rebuilds the Workbox precache manifest and deploys to the main
Cloudflare Pages branch. Do not invoke Wrangler directly for this publication.
The script publishes Atlas datasets from disk, so refresh them from production
before deploying. Run from the repository root and stop if any download fails:

```sh
for f in atlas.json.gz atlas-view.json.gz atlas-mini.json atlas-avatar-cache.json atlas-theme-cache.json atlas-summaries.json atlas-summaries-lite.json; do
  curl -fsSo "site/$f" "https://pub-search.waow.tech/$f" || exit 1
done
site/deploy.sh
```

The dataset is `atlas.json.gz`; `/atlas.json` can return the SPA HTML fallback.
Verify the published site and Atlas after deployment.

## MCP packaging

The installable project is `pub-search-mcp/server/`. This nesting works around a
Horizon builder issue where a single-segment project path is treated as a PyPI
package name. Before flattening it, verify the fix for prefecthq/horizon#3814
against the deployed builder. Tests run with `uv run pytest` from that directory.
