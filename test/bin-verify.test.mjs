// The binaries in bin/ are the ones db/ makes: tools/verify-bin.sh --check on
// every npm test, and a copy of the tree shows it refuses a byte or a source
// that moved without a rebuild.
import test from "node:test"
import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { appendFileSync, cpSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { ROOT, tempDir } from "./lib/bin-fixture.mjs"

function verify(root) {
  const r = spawnSync("bash", [join(root, "tools", "verify-bin.sh"), "--check"], { encoding: "utf8" })
  return { status: r.status, out: r.stdout + r.stderr }
}

test("verify-bin --check passes on the committed tree", () => {
  const r = verify(ROOT)
  assert.equal(r.status, 0, r.out)
  assert.match(r.out, /verify-bin: ok \(check\)/)
})

test("verify-bin --check refuses a changed byte of a binary and a source changed without a rebuild", (t) => {
  const copy = (name) => {
    const root = join(tempDir(t), name)
    for (const part of ["bin", "db", "tools"]) cpSync(join(ROOT, part), join(root, part), { recursive: true })
    return root
  }
  const clean = copy("clean")
  assert.equal(verify(clean).status, 0, verify(clean).out)

  const flipped = copy("flipped")
  const file = join(flipped, "bin", "omanotes-db.aarch64")
  const bytes = readFileSync(file)
  bytes[bytes.length - 1] ^= 1
  writeFileSync(file, bytes)
  const byte = verify(flipped)
  assert.equal(byte.status, 1)
  assert.match(byte.out, /omanotes-db\.aarch64 does not match BUILD\.json/)

  const edited = copy("edited")
  appendFileSync(join(edited, "db", "Wire.cs"), "\n")
  const source = verify(edited)
  assert.equal(source.status, 1)
  assert.match(source.out, /changed since bin\/ was built/)
})
