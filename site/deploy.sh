#!/usr/bin/env bash
# deploy the site to cloudflare pages. run from anywhere.
#
# regenerates the service worker first — its precache manifest embeds a
# content hash per file, so deploying without regenerating serves stale
# assets to returning visitors.
set -euo pipefail
cd "$(dirname "$0")"

npm install
rm -f sw.js sw.js.map workbox-*.js workbox-*.js.map
npx workbox-cli generateSW workbox-config.cjs
npx wrangler pages deploy . --project-name leaflet-search --branch=main
