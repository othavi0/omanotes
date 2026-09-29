#!/usr/bin/env bash
# The aarch64 sysroot, made only from the packages tools/sysroot.lock pins.
#   tools/sysroot.sh PKGS_DIR   unpack the locked packages found in PKGS_DIR
#   tools/sysroot.sh --check    exit 0 when the sysroot was made from this lock
#   SYSROOT_AARCH64=<dir>       where it lives (default $HOME/.cache/omanotes-build/sysroot-aarch64)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
lock="$root/tools/sysroot.lock"
sysroot="${SYSROOT_AARCH64:-$HOME/.cache/omanotes-build/sysroot-aarch64}"
want="$(sha256sum "$lock" | cut -d' ' -f1)"

if [[ "${1:-}" == --check ]]; then
  if [[ "$(cat "$sysroot/.omanotes-lock" 2> /dev/null)" != "$want" ]]; then
    echo "sysroot: $sysroot was not made from tools/sysroot.lock: run tools/sysroot.sh <packages dir>" >&2
    exit 1
  fi
  exit 0
fi

pkgs="${1:?usage: tools/sysroot.sh PKGS_DIR | --check}"
if [[ -e "$sysroot" && ! -f "$sysroot/.omanotes-lock" ]]; then
  echo "sysroot: $sysroot exists and is not a sysroot this script made; refusing to replace it" >&2
  exit 1
fi
tmp="$sysroot.new"
rm -rf -- "$tmp"
mkdir -p -- "$tmp"
while read -r name _ file sha; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  if [[ "$(sha256sum "$pkgs/$file" | cut -d' ' -f1)" != "$sha" ]]; then
    echo "sysroot: $pkgs/$file does not match its sha256 in tools/sysroot.lock" >&2
    exit 1
  fi
  tar -xJf "$pkgs/$file" -C "$tmp" --exclude .PKGINFO --exclude .BUILDINFO --exclude .MTREE --exclude .INSTALL
done < "$lock"
# The ELF interpreter is /lib/ld-linux-aarch64.so.1; Arch keeps /lib as a link to usr/lib.
ln -sfn usr/lib "$tmp/lib"
echo "$want" > "$tmp/.omanotes-lock"
rm -rf -- "$sysroot"
mv -- "$tmp" "$sysroot"
echo "sysroot: $sysroot made from tools/sysroot.lock"
