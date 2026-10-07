// The toolchain of this machine, as bin/BUILD.json records it. tools/build.sh writes it there,
// and tools/verify-bin.sh --rebuild compares it before it builds, so both read the same facts.
//   node tools/toolchain.mjs                  prints it as JSON
//   node tools/toolchain.mjs --same-as FILE   exit 2, naming each difference, unless FILE records this one
import { readFileSync } from "node:fs"
import { spawnSync } from "node:child_process"
import { createHash } from "node:crypto"

const root = new URL("../", import.meta.url).pathname
// The packages whose files reach the bytes: compiler, linker, binutils, and the libc, libgcc and
// zlib objects of the x86_64 link. tools/toolchain.sh installs them from one archive day.
const PACKAGES = ["clang", "lld", "llvm", "gcc", "glibc", "binutils", "zlib"]

// stdout of a tool, or "none" when it is missing or fails: never equal to a recorded value.
function output(file, args, cwd) {
  const r = spawnSync(file, args, { cwd, encoding: "utf8" })
  return r.status === 0 ? r.stdout.trim() : "none"
}

// The archive day of the first mirror pacman uses, the one tools/toolchain.sh writes.
function alaDate() {
  let list = ""
  try {
    list = readFileSync("/etc/pacman.d/mirrorlist", "utf8")
  } catch {
    return "none"
  }
  const first = /^Server = (\S+)/m.exec(list)?.[1] ?? ""
  return /^https:\/\/archive\.archlinux\.org\/repos\/(\d{4}\/\d{2}\/\d{2})\//.exec(first)?.[1] ?? "none"
}

function packages() {
  // pacman -Q exits 1 when one is missing and still prints the others.
  const r = spawnSync("pacman", ["-Q", ...PACKAGES], { encoding: "utf8" })
  const installed = new Map((r.stdout ?? "").split("\n").filter(Boolean).map((line) => line.split(" ")))
  return Object.fromEntries(PACKAGES.map((name) => [name, installed.get(name) ?? "none"]))
}

function here() {
  const lock = JSON.parse(readFileSync(root + "db/packages.lock.json", "utf8"))
  return {
    // From db/, so global.json picks the SDK.
    sdk: output("dotnet", ["--version"], root + "db"),
    ilcompiler: lock.dependencies["net10.0"]["Microsoft.DotNet.ILCompiler"].resolved,
    clang: output("clang", ["--version"]).split("\n")[0],
    lld: output("ld.lld", ["--version"]).split("\n")[0],
    sysroot: createHash("sha256").update(readFileSync(root + "tools/sysroot.lock")).digest("hex"),
    ala_date: alaDate(),
    packages: packages()
  }
}

const [flag, file] = process.argv.slice(2)
const toolchain = here()
if (flag === undefined) {
  console.log(JSON.stringify(toolchain, null, 2))
} else if (flag === "--same-as" && file) {
  const recorded = JSON.parse(readFileSync(file, "utf8")).toolchain ?? {}
  const keys = [...new Set([...Object.keys(recorded), ...Object.keys(toolchain)])]
  const differ = keys.filter((k) => JSON.stringify(recorded[k]) !== JSON.stringify(toolchain[k]))
  for (const k of differ) {
    console.error(`verify-bin: not comparable: ${k} is ${JSON.stringify(toolchain[k])} here and ${JSON.stringify(recorded[k])} in BUILD.json`)
  }
  process.exit(differ.length > 0 ? 2 : 0)
} else {
  console.error("usage: node tools/toolchain.mjs [--same-as BUILD.json]")
  process.exit(64)
}
