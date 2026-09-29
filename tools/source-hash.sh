#!/usr/bin/env bash
# One hash for every input of the bytes in bin/: each file under db/ (sources,
# props, lock file, BannedSymbols, the fold table), tools/build.sh (the flags)
# and tools/sysroot.lock (the aarch64 libc), by path and content.
set -euo pipefail
cd "$(dirname "$0")/.."
find db tools/build.sh tools/sysroot.lock -type f -not -path 'db/bin/*' -not -path 'db/obj/*' -print0 \
  | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
