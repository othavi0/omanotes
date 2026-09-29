// A backup is a copy of the database beside it, named by the day the caller
// sends; a second one the same day replaces the first, and a failed one leaves it.
import test from "node:test"
import assert from "node:assert/strict"
import { chmodSync, existsSync, readdirSync } from "node:fs"
import { dirname, join } from "node:path"
import { Legacy, legacyDb, rows, run } from "./lib/bin-fixture.mjs"

test("a backup copies every row beside the database, and a second one the same day replaces it", (t) => {
  const path = legacyDb(t)
  const dir = dirname(path)
  const first = run(path, "backup", { day: "2026-09-28" })
  assert.deepEqual(first, { id: 1, value: "scratchpad-2026-09-28.db" })
  const copy = join(dir, "scratchpad-2026-09-28.db")
  for (const table of ["items", "history", "settings", "alarms"]) {
    assert.deepEqual(rows(copy, `SELECT * FROM ${table} ORDER BY id`), rows(path, `SELECT * FROM ${table} ORDER BY id`), table)
  }
  assert.equal(rows(copy, "PRAGMA user_version")[0].user_version, Legacy.MIGRATIONS.length)
  run(path, "item.add", { type: "note", title: "after the first backup" })
  run(path, "backup", { day: "2026-09-28" })
  assert.equal(rows(copy, "SELECT count(*) AS n FROM items WHERE title = 'after the first backup'")[0].n, 1)
  assert.deepEqual(readdirSync(dir).filter((f) => f.endsWith(".tmp")), [], "no temporary file is left")
})

test("a backup into a folder that refuses writes is io and keeps the copy the day already had", (t) => {
  const path = legacyDb(t)
  const dir = dirname(path)
  run(path, "backup", { day: "2026-09-27" })
  const before = rows(join(dir, "scratchpad-2026-09-27.db"), "SELECT count(*) AS n FROM items")[0].n
  chmodSync(dir, 0o555)
  let res
  try {
    res = run(path, "backup", { day: "2026-09-27" })
  } finally {
    chmodSync(dir, 0o755)
  }
  assert.equal(res.err, "io", JSON.stringify(res))
  assert.equal(rows(join(dir, "scratchpad-2026-09-27.db"), "SELECT count(*) AS n FROM items")[0].n, before)
})

test("a day that is not yyyy-mm-dd names no file", (t) => {
  const path = legacyDb(t)
  for (const day of ["2026-9-28", "../../x", "2026-09-28.db", "", "2026/09/28"]) {
    assert.equal(run(path, "backup", { day }).err, "bad_request", JSON.stringify(day))
  }
  assert.equal(existsSync(join(dirname(path), "scratchpad-.db")), false)
})
