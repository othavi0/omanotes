#!/usr/bin/env bash
# One hash for every input of the bytes in bin/: each file under db/ (sources,
# props, lock file, BannedSymbols, the fold table), tools/build.sh (the flags)
# and tools/sysroot.lock (the aarch64 libc), by path and content. In the
# plugin's own checkout only the files git tracks count, so an editor backup
# or any stray file in db/ changes nothing; in a copy of the tree, every file.
set -euo pipefail
cd "$(dirname "$0")/.."
inputs=(db tools/build.sh tools/sysroot.lock)
checkout=false
[[ "$(git rev-parse --show-toplevel 2> /dev/null)" == "$(pwd -P)" ]] && checkout=true
if $checkout; then
  # The csproj compiles every .cs under db/, tracked or not, so an untracked
  # build input would change the bytes without changing this hash.
  stray="$(git ls-files -o --exclude-standard -- db | grep -iE '(\.(cs|csproj|props|targets|json|txt|tsv|editorconfig|globalconfig|rsp)|/nuget\.config)$' || true)"
  if [[ -n "$stray" ]]; then
    printf 'source-hash: untracked build input in db/, add or remove it:\n%s\n' "$stray" >&2
    exit 1
  fi
fi
if $checkout; then
  git ls-files -z -- "${inputs[@]}"
else
  find "${inputs[@]}" -type f -not -path 'db/bin/*' -not -path 'db/obj/*' -print0
fi | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
