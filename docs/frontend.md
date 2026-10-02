# frontend development and releases

The UI is static HTML, CSS, and JavaScript in `site/`, hosted on Cloudflare Pages.
`site/functions/api/[[route]].js` proxies `/api/*` to the backend. GET `/search`
responses have a ten-minute fresh edge cache and thirty-minute stale window;
`?edge=0` bypasses it. Admin routes are never proxied.

## shared loading state

`site/loading.js` defines `<pub-loading>`: a small constellation of moving page
shapes and connecting lines. The default is inline; `size="large"` is for an
initial page load. Put a short description inside the element. It provides a
polite status region and disables animation when reduced motion is requested.
The `createLoader` wrapper supports existing dashboard callers.

Atlas, search results, related documents, summaries, finder text search, labels,
recommendations, subscriptions, Wrapped, and dashboard data use this component.
Keep failure and empty states distinct from loading. Do not leave an animation
running after a request has failed.

The homepage groups source and agent-guide links in its header, keeps the corpus
count linked to stats, and places search help inside the input. The footer links
to browsing surfaces. The compact count exposes an exact count in its tooltip
and accessible label.

## local checks

From the repository root:

```sh
python3 -m http.server 8789
```

Open `/site/` for the homepage or `/site/atlas.html` for the map. This server does
not execute Pages Functions. The homepage uses `http://localhost:8080` for
API calls on localhost; other pages use their own configured endpoint. To test
same-origin `/api/*`, use a Pages development server or a deployed origin. Generated Atlas files must be present locally.

Browser harnesses under `/scripts/tests/` use the actual frontend:

- `atlas-loading.html`: startup timing and topic framing at phone/desktop sizes.
- `atlas-performance.html`: spatial selection, visible-planet caching, and globe-only frames while the camera is still.
- `atlas-gl.html`: GPU rendering checks.

```sh
node --test scripts/tests/atlas-interaction.cjs scripts/tests/atlas-spacing.cjs scripts/tests/atlas-finder.mjs scripts/tests/atlas-summaries.mjs
```

For visual changes, check narrow and desktop layouts, light/dark themes, reduced
motion, loading/error states, and mobile keyboard visibility where relevant.
Emulation does not replace physical iOS Safari gesture checks.

## release

Backend releases follow the repository's GitHub workflow; frontend releases use
`site/deploy.sh`. It regenerates Workbox's content-hashed precache before deploying.
Never deploy the frontend by calling Wrangler directly.

Before a manual UI release, download the current generated files into `site/`:

```sh
for f in atlas.json.gz atlas-mini.json atlas-avatar-cache.json atlas-theme-cache.json atlas-summaries.json atlas-summaries-lite.json; do
  curl --fail --silent --show-error --output "site/$f" "https://pub-search.waow.tech/$f" || break
done
```

Stop if any download fails. Check that the gzip opens, each sidecar is JSON, and
the summary sidecar matches the map before proceeding. Pages' SPA fallback can
return HTML with status 200 for a missing filename; status alone is insufficient.
Do not rebuild or regenerate summaries as a side effect of a UI-only release.

```sh
(cd site && ./deploy.sh)
```

When multiple Cloudflare accounts are configured, set `CLOUDFLARE_ACCOUNT_ID` to
the account owning the existing `leaflet-search` Pages project. Verify the preview
and live site after deployment, including a returning tab's service-worker update.
Atlas uses versioned `?build=` asset URLs; keep `atlas.html` and
`workbox-config.cjs` aligned when changing those versions.
