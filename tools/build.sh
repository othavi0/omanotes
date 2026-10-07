#!/usr/bin/env bash
# The only writer of bin/, run through tools/build-in-container.sh so the
# toolchain is the one CI rebuilds with. The analysis build and the canaries
# first (the gates), then one NativeAOT publish per architecture with the same
# toolchain, the glibc floor and the ELF machine of each, and bin/BUILD.json.
#   OUT=<dir>              where to write (default bin/; verify-bin.sh --rebuild uses a temp dir)
#   BUILD_ROOT=<dir>       build products (default $HOME/.cache/omanotes-build), never inside the plugin folder
#   SYSROOT_AARCH64=<dir>  the aarch64 sysroot (default $BUILD_ROOT/sysroot-aarch64, made by tools/sysroot.sh)
#   SKIP_CANARIES=1        verify-bin.sh --rebuild skips them: they prove the gates, not the bytes
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${OUT:-$root/bin}"
work="${BUILD_ROOT:-$HOME/.cache/omanotes-build}"
export SYSROOT_AARCH64="${SYSROOT_AARCH64:-$work/sysroot-aarch64}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
# A symbol above this refuses to load on an older distro. 2.34 is where glibc
# moved dl* and pthread* into libc; going lower needs an older libc to link against.
glibc_max="2.34"

# Runs a build step quietly and shows its output only when it fails.
quiet() {
  local log
  log="$("$@" 2>&1)" || {
    echo "$log" >&2
    echo "build: failed: $*" >&2
    return 1
  }
}

"$root/tools/sysroot.sh" --check
BUILD_ROOT="$work" quiet "$root/tools/analyze.sh" -nologo
[[ "${SKIP_CANARIES:-0}" == 1 ]] || BUILD_ROOT="$work" "$root/tools/canaries.sh"

source_hash="$("$root/tools/source-hash.sh")"
mkdir -p "$out"
for arch in x86_64 aarch64; do
  case "$arch" in
    x86_64) rid=linux-x64 machine=X86-64 extra=() ;;
    aarch64) rid=linux-arm64 machine=AArch64 extra=("-p:SysRoot=$SYSROOT_AARCH64") ;;
  esac
  rm -rf -- "$work/$arch" "$work/out-$arch"
  # From db/, so global.json pins the SDK. -noAutoResponse: a Directory.Build.rsp in any parent
  # folder would add switches that tools/source-hash.sh does not see.
  (cd "$root/db" && quiet dotnet publish -c Release -r "$rid" -nologo -noAutoResponse \
    -p:InvariantGlobalization=true -p:SourceHash="$source_hash" \
    -p:LinkerFlavor=lld -p:ObjCopyName=llvm-objcopy \
    -p:BuildRoot="$work/$arch/" -o "$work/out-$arch" "${extra[@]}")
  file="$work/out-$arch/omanotes-db"
  floor="$(readelf -V "$file" | grep -o 'GLIBC_[0-9.]*' | cut -c7- | sort -uV | tail -n 1)"
  if [[ "$(printf '%s\n%s\n' "$floor" "$glibc_max" | sort -V | tail -n 1)" != "$glibc_max" ]]; then
    echo "build: $arch needs glibc $floor, above $glibc_max" >&2
    exit 1
  fi
  if ! readelf -h "$file" | grep -q "Machine:.*$machine"; then
    echo "build: $file is not an $machine ELF" >&2
    exit 1
  fi
  install -m 755 "$file" "$out/omanotes-db.$arch"
done

# BUILD.json is data: node writes it, so quoting and layout cannot drift.
OUT="$out" SOURCE="$source_hash" ROOT="$root" node --input-type=module -e '
  import { readFileSync, writeFileSync, statSync } from "node:fs"
  import { execFileSync } from "node:child_process"
  import { createHash } from "node:crypto"
  const { OUT, SOURCE, ROOT, SYSROOT_AARCH64 } = process.env
  const run = (file, args, opts = {}) => execFileSync(file, args, { encoding: "utf8", ...opts }).trim()
  const sha = (path) => createHash("sha256").update(readFileSync(path)).digest("hex")
  const wire = readFileSync(ROOT + "/db/Wire.cs", "utf8")
  const current = Number(/const int Current = (\d+);/.exec(wire)[1])
  const targets = {}
  for (const arch of ["x86_64", "aarch64"]) {
    const file = OUT + "/omanotes-db." + arch
    const versions = run("readelf", ["-V", file]).match(/GLIBC_[0-9.]+/g).map((v) => v.slice(6))
    const glibc = versions.sort((a, b) => a.localeCompare(b, "en", { numeric: true })).at(-1)
    targets[arch] = { sha256: sha(file), bytes: statSync(file).size, glibc }
  }
  const native = OUT + "/omanotes-db." + run("uname", ["-m"])
  const version = JSON.parse(run(native, [String(current), "version"], { env: {} }))
  const doc = {
    protocol: version.protocol,
    schema: version.schema,
    source: SOURCE,
    toolchain: JSON.parse(run(process.execPath, [ROOT + "/tools/toolchain.mjs"])),
    targets
  }
  if (version.source !== SOURCE) throw new Error("the binary reports source " + version.source)
  writeFileSync(OUT + "/BUILD.json", JSON.stringify(doc, null, 2) + "\n")
'
echo "build: bin/omanotes-db.{x86_64,aarch64} from source $source_hash"
