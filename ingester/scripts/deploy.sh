#!/usr/bin/env bash
# Deploy the ingester. Stages the repo-root banned-dids.txt into the build
# context first (it's the shared single source of truth, embedded at comptime
# via ../banned-dids.txt — see ingester/Dockerfile). Run from anywhere.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # ingester/
cp "$here/../banned-dids.txt" "$here/banned-dids.txt"
cd "$here"
exec fly deploy --app leaflet-search-ingester "$@"
