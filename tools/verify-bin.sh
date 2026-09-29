#!/usr/bin/env bash
# "The binary committed is the one the source makes", without CI.
#   --check    (default, under a second; npm test runs it) BUILD.json against the tree, the
#              hashes, the mode in the index, what the native binary reports, its selftest.
#   --rebuild  (a minute or two) builds again into a temp dir and compares bytes. Exit 2 when
#              this toolchain is not the one BUILD.json records: not comparable, not a failure.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bin="$root/bin"
mode="${1:---check}"
fail() {
  echo "verify-bin: $*" >&2
  exit 1
}
# One path of BUILD.json, e.g. `recorded source` or `recorded targets.x86_64.sha256`.
recorded() {
  node -e 'let v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); for (const k of process.argv[2].split(".")) v = v?.[k]; console.log(Array.isArray(v) ? v.join(" ") : v ?? "")' "$bin/BUILD.json" "$1"
}

[[ -f "$bin/BUILD.json" ]] || fail "bin/BUILD.json is missing: run tools/build.sh"
source_hash="$("$root/tools/source-hash.sh")"
[[ "$(recorded source)" == "$source_hash" ]] || fail "db/ or the build inputs changed since bin/ was built (BUILD.json $(recorded source), tree $source_hash): run tools/build.sh"

for arch in x86_64 aarch64; do
  f="$bin/omanotes-db.$arch"
  [[ -x "$f" ]] || fail "$f is missing or not executable"
  [[ "$(sha256sum "$f" | cut -d' ' -f1)" == "$(recorded "targets.$arch.sha256")" ]] || fail "$f does not match BUILD.json"
  if git -C "$root" rev-parse --git-dir > /dev/null 2>&1 && git -C "$root" ls-files --error-unmatch "bin/omanotes-db.$arch" > /dev/null 2>&1; then
    [[ "$(git -C "$root" ls-files -s "bin/omanotes-db.$arch" | cut -d' ' -f1)" == 100755 ]] || fail "bin/omanotes-db.$arch is not mode 100755 in the index"
  fi
done

read -r _ current < <(recorded protocol)
native="$bin/omanotes-db.$(uname -m)"
reported="$(env -i "$native" "$current" version)"
[[ "$reported" == *"\"source\":\"$source_hash\""* ]] || fail "the binary reports another source than BUILD.json: $reported"
# Outside /tmp, which is a small tmpfs here, and a rebuild writes hundreds of MB.
mkdir -p "$HOME/.cache/omanotes-build"
smoke="$(mktemp -d "$HOME/.cache/omanotes-build/verify.XXXXXX")"
trap 'rm -rf -- "$smoke"' EXIT
env -i "$native" "$current" selftest "$smoke" > /dev/null || fail "selftest failed on this machine"

if [[ "$mode" == --check ]]; then
  echo "verify-bin: ok (check)"
  exit 0
fi
[[ "$mode" == --rebuild ]] || fail "usage: tools/verify-bin.sh [--check|--rebuild]"

same_tool() {
  if [[ "$(recorded "toolchain.$1")" != "$2" ]]; then
    echo "verify-bin: not comparable: $1 is '$2' here and '$(recorded "toolchain.$1")' in BUILD.json" >&2
    exit 2
  fi
}
same_tool sdk "$(cd "$root/db" && dotnet --version)"
same_tool clang "$(clang --version | head -n 1)"
same_tool lld "$(ld.lld --version | head -n 1)"
same_tool sysroot "$(sha256sum "$root/tools/sysroot.lock" | cut -d' ' -f1)"
OUT="$smoke/bin" BUILD_ROOT="$smoke/build" SYSROOT_AARCH64="${SYSROOT_AARCH64:-$HOME/.cache/omanotes-build/sysroot-aarch64}" SKIP_CANARIES=1 "$root/tools/build.sh" > /dev/null
for arch in x86_64 aarch64; do
  cmp -s "$bin/omanotes-db.$arch" "$smoke/bin/omanotes-db.$arch" || fail "$arch: a rebuild from source gives other bytes than bin/"
done
echo "verify-bin: ok (rebuild gave the same bytes for x86_64 and aarch64)"
