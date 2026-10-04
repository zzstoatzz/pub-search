#!/bin/sh
# Pre-fetch every build dep before `zig build` runs, so transient
# tangled.* network blips don't break Docker builds.
#
# The fetch goes through `zig build --fetch`, not `zig fetch <url>`: on zig
# 0.17.0 a standalone `zig fetch <url>` caches the tarball with the archive's
# top-level directory still inside it, and the build that reads it back then
# reports a hash mismatch for every dependency.
#
# If tangled stays down, deps hosted under zzstoatzz.io are retried from the
# github.com/zzstoatzz mirror by rewriting their urls in build.zig.zon. Hashes
# validate either source — if a mirror were ever to drift, zig would refuse
# the tarball rather than silently use it.
#
# Run from the directory containing build.zig.zon.

set -eu

fetch_with_retry() {
  n=0
  while [ $n -lt 3 ]; do
    if zig build --fetch; then return 0; fi
    n=$((n + 1))
    [ $n -lt 3 ] && sleep $((n * 2))
  done
  return 1
}

if fetch_with_retry; then exit 0; fi

echo ">>> primary fetch failed, retrying zzstoatzz.io deps from the github mirror" >&2
sed -i.orig \
  -e 's|https://tangled\.sh/@zzstoatzz\.io/|https://github.com/zzstoatzz/|' \
  -e 's|https://tangled\.org/zzstoatzz\.io/|https://github.com/zzstoatzz/|' \
  build.zig.zon
fetch_with_retry
