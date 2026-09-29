// The wire: argv, stdin, stdout only on exit 0, the error as the last line of
// stderr, and exit 0, 1 or 64.
import test from "node:test"
import assert from "node:assert/strict"
import { spawn, spawnSync } from "node:child_process"
import { existsSync, mkdirSync, readdirSync, symlinkSync } from "node:fs"
import { machine } from "node:os"
import { join } from "node:path"
import { BIN, BUILD, PROTOCOL, ROOT, call, exec, lastError, rows, run, sync, tempDb, tempDir, write } from "./lib/bin-fixture.mjs"

const CODES = ["protocol", "bad_request", "timeout", "too_large", "busy", "not_found", "refused", "forbidden", "io",
  "corrupt", "sqlite", "sqlite_missing", "sqlite_too_old", "selftest", "internal"]

function fails(r, status, err) {
  assert.equal(r.status, status, r.stderr)
  assert.equal(r.stdout, "", "stdout carries nothing unless the exit is 0")
  assert.equal(lastError(r.stderr).err, err, r.stderr)
}

test("version names the protocols, the schema, the source, the machine and every error code", () => {
  const r = exec([PROTOCOL, "version"])
  assert.equal(r.status, 0, r.stderr)
  const v = JSON.parse(r.stdout)
  assert.deepEqual(v.protocol, BUILD.protocol)
  assert.equal(v.schema, BUILD.schema)
  assert.equal(v.source, BUILD.source)
  assert.equal(v.arch, machine())
  assert.equal(v.sqliteMin, "3.44.0")
  assert.match(v.sqlite, /^3\.\d+\.\d+$/)
  assert.deepEqual(v.errors, CODES)
})

test("another protocol or another command line is exit 64 with protocol, and nothing on stdout", (t) => {
  const db = tempDb(t)
  const [min, current] = BUILD.protocol
  fails(exec([String(current + 1), "version"]), 64, "protocol")
  fails(exec([String(min - 1), "run", db], "{}"), 64, "protocol")
  fails(exec(["1x", "version"]), 64, "protocol")
  fails(exec([]), 64, "protocol")
  fails(exec([PROTOCOL]), 64, "protocol")
  fails(exec([PROTOCOL, "frob"]), 64, "protocol")
  fails(exec([PROTOCOL, "run"]), 64, "protocol")
  fails(exec([PROTOCOL, "run", "relative/scratchpad.db"], "{}"), 64, "protocol")
  fails(exec([PROTOCOL, "selftest", "."]), 64, "protocol")
  assert.equal(existsSync(db), false, "a refused command line opens no file")
})

test("a request with a wrong envelope is bad_request, exit 1, and runs none of its writes", (t) => {
  const db = tempDb(t)
  const good = write("item.add", { type: "note", title: "never" })
  for (const [label, body] of [
    ["not JSON", "{\"writes\": ["],
    ["invalid UTF-8", Buffer.from([0x7b, 0xff, 0x7d])],
    ["an array", "[]"],
    ["empty stdin", ""],
    ["nothing to do", "{}"],
    ["an unknown member", JSON.stringify({ writes: [good], extra: 1 })],
    ["writes that are not an array", JSON.stringify({ writes: good })],
    ["an unknown op", JSON.stringify({ writes: [good, write("item.nuke", {}, { id: 2 })] })],
    ["a sender that is neither", JSON.stringify({ writes: [good, write("item.add", { type: "note", title: "x" }, { by: "panel", id: 2 })] })],
    ["a negative at", JSON.stringify({ writes: [write("item.add", { type: "note", title: "x" }, { at: -1 })] })],
    ["a fractional id", JSON.stringify({ writes: [{ ...good, id: 1.5 }] })],
    ["a view key twice", JSON.stringify({ sync: { views: [{ key: "a", filter: "all", query: "x" }, { key: "a", filter: "all", query: "y" }] } })]
  ]) {
    const r = exec([PROTOCOL, "run", db], body)
    fails(r, 1, "bad_request")
    if (existsSync(db)) assert.equal(rows(db, "SELECT count(*) AS n FROM items")[0].n, 0, label)
  }
})

test("a write with wrong args is its own bad_request and the others run", (t) => {
  const db = tempDb(t)
  const res = call(db, { writes: [
    write("item.add", { type: "note" }, { id: 1 }),
    write("item.add", { type: "note", title: "x", bod: "misspelled" }, { id: 2 }),
    write("item.status", { id: "3", status: 1 }, { id: 3 }),
    write("item.status", { id: 1, status: 2 }, { id: 4 }),
    write("item.move", { id: 1, anchorId: 2, after: "yes" }, { id: 5 }),
    write("history.prune", { days: 0 }, { id: 6 }),
    write("item.add", { type: "note", title: "x\ud800y" }, { id: 7 }),
    write("item.add", { type: "note", title: "kept" }, { id: 8 })
  ] })
  assert.deepEqual(res.results.map((r) => r.err ?? r.value), ["bad_request", "bad_request", "bad_request", "bad_request", "bad_request", "bad_request", "bad_request", 1])
  assert.deepEqual(res.results[6], { id: 7, err: "bad_request", detail: "title holds a lone surrogate" })
  assert.deepEqual(rows(db, "SELECT title FROM items"), [{ title: "kept" }])
})

test("a request up to 1 MiB goes through; one byte more is too_large and writes nothing", (t) => {
  const db = tempDb(t)
  const frame = (body) => JSON.stringify({ writes: [write("item.add", { type: "note", title: "big", body })] })
  const room = (1 << 20) - frame("").length
  const body = "é".repeat(Math.floor(room / 2)) + "x".repeat(room % 2)
  const fits = frame(body)
  assert.equal(Buffer.byteLength(fits), 1 << 20)
  const ok = JSON.parse(exec([PROTOCOL, "run", db], fits).stdout)
  assert.equal(ok.results[0].value, 1)
  assert.equal(rows(db, "SELECT length(body) AS n FROM items")[0].n, body.length)
  const over = frame("x".repeat(room + 1))
  fails(exec([PROTOCOL, "run", db], over), 1, "too_large")
  assert.equal(rows(db, "SELECT count(*) AS n FROM items")[0].n, 1)
})

test("a stdin that never closes ends in timeout after about 2 s instead of hanging", async (t) => {
  const db = tempDb(t)
  const start = Date.now()
  const r = await new Promise((resolve) => {
    const child = spawn(BIN, [PROTOCOL, "run", db], { env: {} })
    let out = ""
    let err = ""
    child.stdout.on("data", (d) => { out += d })
    child.stderr.on("data", (d) => { err += d })
    child.stdin.write("{\"writes\":")
    const guard = setTimeout(() => child.kill("SIGKILL"), 10000)
    child.on("close", (status) => {
      clearTimeout(guard)
      resolve({ status, stdout: out, stderr: err })
    })
  })
  const ms = Date.now() - start
  fails(r, 1, "timeout")
  assert.ok(ms >= 1900 && ms < 6000, `ended after ${ms} ms`)
})

test("the response is the writes' results, then the snapshot after them, and only on exit 0", (t) => {
  const db = tempDb(t)
  const r = exec([PROTOCOL, "run", db], { writes: [write("item.add", { type: "todo", title: "Olá, ação" })], sync: { since: -1, views: [{ key: "s", filter: "todo", query: "acao" }] } })
  assert.equal(r.status, 0, r.stderr)
  assert.ok(r.stdout.includes("Olá, ação"), "non-ASCII text is not escaped")
  const res = JSON.parse(r.stdout)
  assert.deepEqual(Object.keys(res), ["results", "snapshot"])
  assert.deepEqual(res.results, [{ id: 1, value: 1 }])
  assert.deepEqual(res.snapshot.items.map((i) => i.title), ["Olá, ação"])
  assert.deepEqual(res.snapshot.matches, { s: [1] })
  assert.deepEqual(Object.keys(res.snapshot), ["stamp", "unchanged", "settings", "counts", "items", "history", "alarms", "matches"])
  assert.deepEqual(res.snapshot.counts, { unreadNotes: 0, pendingTodos: 1, notes: 0, todos: 1, history: 1, oldest: 1700000000 })
  assert.match(r.stderr, /^omanotes-db: migrated 0 -> 5\n$/)
  assert.deepEqual(Object.keys(call(db, { writes: [write("history.clear")] })), ["results"], "no sync, no snapshot")
})

test("the same request gives the same answer whatever the environment holds", (t) => {
  const db = tempDb(t)
  sync(db)
  const request = { sync: { since: -1, views: [] } }
  const bare = exec([PROTOCOL, "run", db], request).stdout
  const noisy = exec([PROTOCOL, "run", db], request, { env: { ...process.env, TZ: "Pacific/Kiritimati", LANG: "tr_TR.UTF-8", LC_ALL: "tr_TR.UTF-8", TMPDIR: "/nonexistent", HOME: "/nonexistent" } }).stdout
  assert.equal(noisy, bare)
})

test("selftest migrates, writes, reads and removes a database on disk in the folder it is given", (t) => {
  const dir = join(tempDir(t), "smoke")
  const r = exec([PROTOCOL, "selftest", dir])
  assert.equal(r.status, 0, r.stderr)
  assert.equal(r.stdout, "{\"ok\":true}\n")
  assert.deepEqual(readdirSync(dir), [], "the selftest database is gone")
})

const QEMU = "/usr/bin/qemu-aarch64-static"
const SYSROOT = process.env.SYSROOT_AARCH64 ?? join(process.env.HOME ?? "", ".cache/omanotes-build/sysroot-aarch64")
const armReady = existsSync(QEMU) && existsSync(join(SYSROOT, "usr/lib/libc.so.6"))

test("the aarch64 binary passes its selftest under qemu, and without libsqlite3 says sqlite_missing", { skip: !armReady && "needs qemu-aarch64-static and the sysroot of tools/sysroot.sh" }, (t) => {
  const armBin = join(ROOT, "bin", "omanotes-db.aarch64")
  const ok = qemu(SYSROOT, [armBin, PROTOCOL, "selftest", join(tempDir(t), "smoke")])
  assert.equal(ok.status, 0, ok.stderr)
  assert.equal(ok.stdout, "{\"ok\":true}\n")
  // The same sysroot with every file but libsqlite3.
  const bare = join(tempDir(t), "sysroot")
  mkdirSync(join(bare, "usr/lib"), { recursive: true })
  for (const f of readdirSync(join(SYSROOT, "usr/lib"))) if (!f.startsWith("libsqlite3")) symlinkSync(join(SYSROOT, "usr/lib", f), join(bare, "usr/lib", f))
  symlinkSync("usr/lib", join(bare, "lib"))
  fails(qemu(bare, [armBin, PROTOCOL, "run", tempDb(t)], "{\"sync\":{}}"), 1, "sqlite_missing")
})

function qemu(sysroot, args, input = "") {
  const r = spawnSync(QEMU, ["-L", sysroot, ...args], { input, env: {} })
  return { status: r.status, stdout: r.stdout.toString("utf8"), stderr: r.stderr.toString("utf8") }
}
