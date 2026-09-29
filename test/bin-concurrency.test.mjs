// Locks, transactions and several writers at once.
import test from "node:test"
import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import { existsSync } from "node:fs"
import { BIN, PROTOCOL, call, cli, holdLock, rows, run, sync, tempDb, write } from "./lib/bin-fixture.mjs"

function timed(fn) {
  const start = process.hrtime.bigint()
  const value = fn()
  return { value, ms: Number(process.hrtime.bigint() - start) / 1e6 }
}

test("a write lock held outside makes a write wait 5 s and answer busy, and the snapshot still reads", async (t) => {
  const path = tempDb(t)
  sync(path)
  const release = await holdLock(path, "IMMEDIATE")
  let r
  try {
    r = timed(() => call(path, { writes: [write("item.add", { type: "note", title: "blocked" })], sync: { since: -1, views: [] } }))
  } finally {
    await release()
  }
  assert.equal(r.value.results[0].err, "busy", JSON.stringify(r.value.results))
  assert.equal(r.value.results[0].detail, "database is locked")
  assert.ok(r.ms >= 4900 && r.ms < 8000, `waited ${r.ms} ms`)
  assert.deepEqual(r.value.snapshot.items, [], "the read went on beside the lock")
  // Nothing of the busy write stayed behind: a write from outside goes through at once.
  cli(path, "INSERT INTO history (type, title, action, ts) VALUES ('note', 'after', 'added', 1)")
  assert.equal(rows(path, "SELECT count(*) AS n FROM items")[0].n, 0)
})

test("an exclusive lock held outside fails the whole request with busy after 5 s", async (t) => {
  const path = tempDb(t)
  sync(path)
  const release = await holdLock(path, "EXCLUSIVE")
  let r
  try {
    r = timed(() => call(path, { writes: [write("item.add", { type: "note", title: "blocked" })], sync: { since: -1, views: [] } }))
  } finally {
    await release()
  }
  assert.equal(r.value.status, 1)
  assert.deepEqual(r.value.error, { err: "busy", detail: "database is locked" })
  assert.ok(r.ms >= 4900 && r.ms < 8000, `waited ${r.ms} ms`)
  assert.equal(run(path, "item.add", { type: "note", title: "after" }).value, 1, "the file works once the lock is gone")
})

test("a write whose second statement aborts leaves nothing: no row, no history, no journal, no lock", (t) => {
  const path = tempDb(t)
  sync(path)
  cli(path, "CREATE TRIGGER boom BEFORE INSERT ON history BEGIN SELECT RAISE(ABORT, 'boom'); END")
  const res = call(path, { writes: [write("item.add", { type: "note", title: "atomic?" }), write("item.add", { type: "todo", title: "second" }, { id: 2 })] })
  assert.deepEqual(res.results, [{ id: 1, err: "refused", detail: "boom" }, { id: 2, err: "refused", detail: "boom" }])
  assert.equal(rows(path, "SELECT count(*) AS n FROM items")[0].n, 0)
  assert.equal(existsSync(path + "-journal"), false)
  cli(path, "DROP TRIGGER boom")
  assert.equal(run(path, "item.add", { type: "note", title: "then" }).value, 1)
})

test("a refused write does not stop the next, and each is its own transaction", (t) => {
  const path = tempDb(t)
  const res = call(path, { writes: [
    write("item.add", { type: "note", title: "one" }, { id: 1 }),
    write("item.status", { id: 42, status: 1 }, { id: 2 }),
    write("item.add", { type: "memo", title: "bad type" }, { id: 3 }),
    write("item.add", { type: "todo", title: "two" }, { id: 4 })
  ] })
  assert.deepEqual(res.results.map((r) => [r.id, r.value ?? r.err]), [[1, 1], [2, "not_found"], [3, "bad_request"], [4, 2]])
  assert.deepEqual(rows(path, "SELECT id, title FROM items ORDER BY id"), [{ id: 1, title: "one" }, { id: 2, title: "two" }])
  assert.equal(rows(path, "SELECT count(*) AS n FROM history")[0].n, 2)
})

test("eight processes writing five items each lose nothing", async (t) => {
  const path = tempDb(t)
  sync(path)
  const runs = await Promise.all(Array.from({ length: 8 }, (_, p) => new Promise((resolve) => {
    const child = spawn(BIN, [PROTOCOL, "run", path], { env: {} })
    let out = ""
    child.stdout.on("data", (d) => { out += d })
    child.on("close", (status) => resolve({ status, out }))
    const writes = Array.from({ length: 5 }, (_, i) => write("item.add", { type: "note", title: `p${p} n${i}` }, { id: i }))
    child.stdin.end(JSON.stringify({ writes }))
  })))
  for (const r of runs) {
    assert.equal(r.status, 0)
    assert.ok(JSON.parse(r.out).results.every((x) => typeof x.value === "number"), r.out)
  }
  assert.equal(rows(path, "SELECT count(DISTINCT id) AS n FROM items")[0].n, 40)
  assert.equal(rows(path, "SELECT count(*) AS n FROM history")[0].n, 40)
})

test("the stamp answers unchanged until the file changes, and never in WAL", (t) => {
  const path = tempDb(t)
  const first = sync(path)
  assert.ok(first.stamp > 0)
  assert.deepEqual(sync(path, first.stamp), { stamp: first.stamp, unchanged: true })
  run(path, "item.add", { type: "note", title: "x" })
  const second = sync(path, first.stamp)
  assert.equal(second.unchanged, false)
  assert.ok(second.stamp > first.stamp)
  assert.equal(second.items.length, 1)
  // Someone switched the file to WAL by hand: the counter no longer moves, so nothing is ever skipped.
  cli(path, "PRAGMA journal_mode = WAL")
  const wal = sync(path, second.stamp)
  assert.equal(wal.stamp, -1)
  assert.equal(wal.unchanged, false)
  assert.equal(sync(path, -1).unchanged, false)
  assert.equal(cli(path, "PRAGMA journal_mode").trim(), "wal", "the binary leaves the journal mode it found")
})

test("a snapshot that cannot be read keeps the results of the writes before it", (t) => {
  const path = tempDb(t)
  sync(path)
  cli(path, "DROP TABLE settings")
  const res = call(path, { writes: [write("item.add", { type: "note", title: "kept" })], sync: { since: -1, views: [] } })
  assert.equal(res.results[0].value, 1)
  assert.equal(res.snapshot, undefined)
  assert.deepEqual(res.syncErr, { err: "sqlite", detail: "no such table: settings" })
  assert.equal(rows(path, "SELECT title FROM items")[0].title, "kept")
})
