// The binary migrates to the schema the JS migrations built, character for
// character, with the same search_map, and only one process migrates a file.
import test from "node:test"
import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { BIN, Db, PROTOCOL, ROOT, call, cli, legacyDb, legacyNewDb, rows, sync, tempDb, v0Db } from "./lib/bin-fixture.mjs"

const SEARCH_MAP_SHA256 = "406fc008e11b15b16017733b3afa05e9060b166340dbf01d238996b07d371382"

// search_map as a TSV: the unit, a tab, the code points it folds to, all hex.
function foldTable(dbPath) {
  const hex = (s) => [...s].map((c) => c.codePointAt(0).toString(16).padStart(4, "0")).join(" ")
  return rows(dbPath, "SELECT ch, folded FROM search_map ORDER BY ch").map((r) => hex(r.ch) + "\t" + hex(r.folded)).join("\n") + "\n"
}

const sha256 = (text) => createHash("sha256").update(text).digest("hex")

function master(dbPath) {
  return rows(dbPath, "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name")
}

test("the versioned fold table is the searchText of before the binary, and its sha256 is the live database's", () => {
  const file = readFileSync(join(ROOT, "db", "Schema", "search_map.tsv"), "utf8")
  assert.equal(sha256(file), SEARCH_MAP_SHA256)
  const hex = (s) => [...s].map((c) => c.codePointAt(0).toString(16).padStart(4, "0")).join(" ")
  const lines = []
  for (let u = 0; u < 0x10000; u++) {
    const c = String.fromCharCode(u)
    const folded = Db.searchText(c)
    if (folded !== c) lines.push(u.toString(16).padStart(4, "0") + "\t" + hex(folded))
  }
  assert.equal(lines.length, 2299)
  assert.equal(lines.join("\n") + "\n", file)
})

test("a new file migrates to the schema and the search_map the JS migrations make", (t) => {
  const bin = tempDb(t)
  sync(bin)
  const old = legacyNewDb(t)
  assert.deepEqual(master(bin), master(old))
  assert.equal(rows(bin, "PRAGMA user_version")[0].user_version, Db.MIGRATIONS.length)
  assert.equal(sha256(foldTable(bin)), SEARCH_MAP_SHA256)
  assert.equal(foldTable(bin), foldTable(old))
  assert.deepEqual(rows(bin, "SELECT * FROM settings"), rows(old, "SELECT * FROM settings"))
  assert.equal(cli(bin, "PRAGMA journal_mode").trim(), "delete", "the binary never turns WAL on")
})

test("a v0 file with rows migrates to the rows the JS migrations leave", (t) => {
  const bin = v0Db(t)
  const old = legacyDb(t)
  const res = call(bin, { sync: { since: -1, views: [] } })
  assert.ok(res.snapshot)
  assert.deepEqual(master(bin), master(old))
  for (const table of ["items", "history", "alarms", "settings", "sqlite_sequence"]) {
    assert.deepEqual(rows(bin, `SELECT * FROM ${table} ORDER BY 1`), rows(old, `SELECT * FROM ${table} ORDER BY 1`), table)
  }
  assert.ok(rows(bin, "SELECT count(*) AS n FROM items WHERE search_title IS NOT NULL")[0].n >= 5, "the backfill folded the rows")
})

test("a file above the current version is used as it is", (t) => {
  const path = tempDb(t)
  sync(path)
  cli(path, "PRAGMA user_version = 9")
  const snap = sync(path)
  assert.equal(snap.unchanged, false)
  assert.equal(rows(path, "PRAGMA user_version")[0].user_version, 9)
})

test("six processes opening one new file migrate it once", async (t) => {
  const path = tempDb(t)
  const runs = await Promise.all(Array.from({ length: 6 }, (_, i) => new Promise((resolve) => {
    const child = spawn(BIN, [PROTOCOL, "run", path], { env: {} })
    let out = ""
    let err = ""
    child.stdout.on("data", (d) => { out += d })
    child.stderr.on("data", (d) => { err += d })
    child.on("close", (status) => resolve({ status, out, err }))
    child.stdin.end(JSON.stringify({ writes: [{ id: i, by: "widget", op: "item.add", at: 1, args: { type: "note", title: "n" + i } }], sync: { since: -1, views: [] } }))
  })))
  for (const r of runs) assert.equal(r.status, 0, r.err)
  assert.equal(runs.filter((r) => r.err.includes("migrated 0 -> 5")).length, 1, runs.map((r) => r.err).join("|"))
  assert.equal(rows(path, "SELECT count(*) AS n FROM search_map")[0].n, 2299)
  assert.equal(rows(path, "SELECT count(*) AS n FROM items")[0].n, 6)
  assert.equal(rows(path, "SELECT count(*) AS n FROM settings")[0].n, 1)
})
