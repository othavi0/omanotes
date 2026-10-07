// tools/verify-bin.sh --rebuild runs as root in CI, so no file of bin/ may run before a rebuild
// from source gave the same bytes: a binary that runs first can change what the comparison says.
import test from "node:test"
import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { createHash } from "node:crypto"
import { tmpdir } from "node:os"
import { join } from "node:path"

const ROOT = new URL("../", import.meta.url).pathname

test("--rebuild refuses bytes that differ from a rebuild without running them", (t) => {
  const dir = mkdtempSync(join(tmpdir(), "omanotes-verify-"))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  const env = { PATH: process.env.PATH, HOME: dir }
  const out = (file, args = []) => {
    const r = spawnSync(file, args, { cwd: tree, env, encoding: "utf8" })
    assert.equal(r.status, 0, r.stderr)
    return r.stdout.trim()
  }

  // A copy of the tree outside git, whose build.sh makes other bytes than the planted ones.
  const tree = join(dir, "tree")
  for (const part of ["db", "tools"]) cpSync(join(ROOT, part), join(tree, part), { recursive: true })
  writeFileSync(join(tree, "tools/build.sh"), '#!/bin/sh\nmkdir -p "$OUT"\nfor a in x86_64 aarch64; do echo rebuilt > "$OUT/omanotes-db.$a"; done\n', { mode: 0o755 })
  const source = out(join(tree, "tools/source-hash.sh"))
  const toolchain = JSON.parse(out(process.execPath, [join(tree, "tools/toolchain.mjs")]))

  // Each planted binary leaves a mark when it runs and answers as the real one would.
  const mark = join(dir, "ran")
  mkdirSync(join(tree, "bin"))
  const targets = {}
  for (const arch of ["x86_64", "aarch64"]) {
    const file = join(tree, "bin", "omanotes-db." + arch)
    writeFileSync(file, `#!/bin/sh\ntouch '${mark}'\necho '{"source":"${source}"}'\n`, { mode: 0o755 })
    targets[arch] = { sha256: createHash("sha256").update(readFileSync(file)).digest("hex") }
  }
  const build = JSON.parse(readFileSync(join(ROOT, "bin/BUILD.json"), "utf8"))
  writeFileSync(join(tree, "bin/BUILD.json"), JSON.stringify({ ...build, source, toolchain, targets }))

  const r = spawnSync(join(tree, "tools/verify-bin.sh"), ["--rebuild"], { env, encoding: "utf8" })
  assert.equal(existsSync(mark), false, "a file of bin/ ran before the rebuild matched it")
  assert.equal(r.status, 1, r.stderr)
  assert.match(r.stderr, /x86_64: a rebuild from source gives other bytes than bin\//)
})
