#!/usr/bin/env bash
# The way to write bin/: tools/build.sh, analysis and canaries included, in the toolchain of
# tools/toolchain.env, which .github/workflows/verify-bin.yml rebuilds with.
#   tools/build-in-container.sh           writes bin/ and bin/BUILD.json
#   tools/build-in-container.sh --verify  runs tools/verify-bin.sh --rebuild against bin/
# Needs docker. tools/toolchain.sh runs once into a local image named after the hash of what
# makes it; the build runs as the calling user, so bin/ stays theirs.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
  "") run=(tools/build.sh) ;;
  --verify) run=(tools/verify-bin.sh --rebuild) ;;
  *)
    echo "usage: tools/build-in-container.sh [--verify]" >&2
    exit 64
    ;;
esac
"$root/tools/toolchain.sh" --image > /dev/null
# shellcheck source=tools/toolchain.env
source "$root/tools/toolchain.env"

image="omanotes-toolchain:$(cat "$root"/tools/{toolchain.env,toolchain.sh,sysroot.lock,sysroot.sh} | sha256sum | cut -c1-12)"
if ! docker image inspect "$image" > /dev/null 2>&1; then
  container="$(docker create -v "$root:/src:ro" "$IMAGE" /src/tools/toolchain.sh)"
  trap 'docker rm -f "$container" > /dev/null' EXIT
  docker start -a "$container"
  docker commit "$container" "$image" > /dev/null
fi

# A worktree's .git file names a folder of the main checkout: git reads it at the same path.
mounts=(-v "$root:$root")
common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2> /dev/null || true)"
[[ -n "$common" && "$common" != "$root"/* ]] && mounts+=(-v "$common:$common:ro")
# NuGet's cache and the build products, kept between runs.
home="$HOME/.cache/omanotes-build/container-home"
mkdir -p "$home"
docker run --rm --user "$(id -u):$(id -g)" "${mounts[@]}" -v "$home:/home/build" \
  -e HOME=/home/build -e SYSROOT_AARCH64=/opt/sysroot-aarch64 -w "$root" "$image" "${run[@]}"
