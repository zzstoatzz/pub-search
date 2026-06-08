#!/bin/sh
# Pre-fetch every build dep before `zig build` runs, so transient
# tangled.* network blips don't break Docker builds.
#
# For deps hosted on tangled.* under zzstoatzz.io / @zzstoatzz.io, fall
# back to the github.com/zzstoatzz mirror on failure. Hashes in
# build.zig.zon validate either source — if a mirror were ever to drift,
# zig would refuse the tarball rather than silently use it.
#
# Run from the directory containing build.zig.zon.

set -eu

fetch_with_retry() {
  url=$1
  n=0
  while [ $n -lt 3 ]; do
    if zig fetch "$url"; then return 0; fi
    n=$((n + 1))
    [ $n -lt 3 ] && sleep $((n * 2))
  done
  return 1
}

fetch_one() {
  primary=$1
  if fetch_with_retry "$primary"; then return 0; fi
  fb=""
  case "$primary" in
    https://tangled.sh/@zzstoatzz.io/*)
      fb=$(printf '%s' "$primary" | sed 's|tangled\.sh/@zzstoatzz\.io|github.com/zzstoatzz|') ;;
    https://tangled.org/zzstoatzz.io/*)
      fb=$(printf '%s' "$primary" | sed 's|tangled\.org/zzstoatzz\.io|github.com/zzstoatzz|') ;;
  esac
  if [ -n "$fb" ]; then
    echo ">>> primary failed, trying github mirror: $fb" >&2
    fetch_with_retry "$fb"
  else
    return 1
  fi
}

sed -nE 's/.*\.url = "([^"]+)".*/\1/p' build.zig.zon | while IFS= read -r url; do
  [ -z "$url" ] && continue
  echo "==> $url"
  fetch_one "$url" || { echo "FAILED: $url" >&2; exit 1; }
done
