#!/usr/bin/env bash
# One hash for every input of the bytes in bin/: each file under db/ (sources,
# props, lock file, BannedSymbols, the fold table), tools/build.sh (the flags)
# and tools/sysroot.lock (the aarch64 libc), by path and content. In the
# plugin's own checkout only the files git tracks count, so an editor backup
# or any stray file in db/ changes nothing; in a copy of the tree, every file.
set -euo pipefail
cd "$(dirname "$0")/.."
inputs=(db tools/build.sh tools/sysroot.lock)
if [[ "$(git rev-parse --show-toplevel 2> /dev/null)" == "$(pwd -P)" ]]; then
  git ls-files -z -- "${inputs[@]}"
else
  find "${inputs[@]}" -type f -not -path 'db/bin/*' -not -path 'db/obj/*' -print0
fi | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
