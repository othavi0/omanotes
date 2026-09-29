#!/usr/bin/env bash
# Every gate is proven by a file that breaks it. Each tools/canaries/NAME.cs.txt
# is dropped as Canary.cs into a copy of db/, and the analysis build must fail
# with the diagnostic its first line names (`//! expect: ID`) on Canary.cs
# itself. A gate that stops firing (a package update, an .editorconfig edit)
# fails here, not in a review.
#   tools/canaries.sh [NAME...]  all of them, or only these
#   BUILD_ROOT=<dir>             build products (default $HOME/.cache/omanotes-build)
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="${BUILD_ROOT:-$HOME/.cache/omanotes-build}/canaries"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
rm -rf -- "$work"
bad=0
count=0
canaries=("$root"/tools/canaries/*.cs.txt)
[[ $# -gt 0 ]] && canaries=("${@/#/$root/tools/canaries/}") && canaries=("${canaries[@]/%/.cs.txt}")
for canary in "${canaries[@]}"; do
  name="$(basename "$canary" .cs.txt)"
  want="$(sed -n '1s#^//! expect: ##p' "$canary")"
  mkdir -p "$work/$name"
  cp -r "$root/db" "$work/$name/db"
  cp "$canary" "$work/$name/db/Canary.cs"
  out="$(cd "$work/$name/db" && dotnet build -c Release -nologo -p:InvariantGlobalization=false -p:BuildRoot="$work/$name/build/" 2>&1)"
  count=$((count + 1))
  if grep -q "Canary.cs([0-9,]*): error $want" <<< "$out"; then
    echo "ok   $name refused with $want"
  else
    echo "FAIL $name: no $want on Canary.cs"
    grep -m3 " error " <<< "$out" | sed 's/ \[.*//' | cut -c1-200
    bad=1
  fi
done
rm -rf -- "$work"
[[ "$bad" == 0 ]] && echo "canaries: $count of $count refused as expected"
exit "$bad"
