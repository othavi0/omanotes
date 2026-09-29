// The binary migrates to the schema the JS migrations built, character for
// character, with the same search_map, and only one process migrates a file.
// What the JS migrations built is frozen in test/fixtures/parity/schema.json.
import test from "node:test"
import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { BIN, PROTOCOL, ROOT, V0_SCHEMA, call, cli, fixture, projectedRows, rows, sync, tempDb, v0Db } from "./lib/bin-fixture.mjs"

const S = fixture("schema.json")

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

// Every frozen sqlite_master entry is in the file, with the same text. A table
// may end in columns a later step added: ALTER TABLE ADD COLUMN appends each to
// the frozen text. A table or index a later step made is not the old SQL's.
function masterHolds(dbPath, frozen) {
  const live = new Map(master(dbPath).map((e) => [e.type + " " + e.name, e]))
  for (const f of frozen) {
    const e = live.get(f.type + " " + f.name)
    assert.ok(e, `${f.type} ${f.name} is in the file`)
    assert.equal(e.tbl_name, f.tbl_name, f.name)
    if (f.type === "table" && e.sql !== f.sql) {
      assert.ok(e.sql.startsWith(f.sql.slice(0, -1) + ", "), `${f.name} keeps its frozen columns: ${e.sql}`)
    } else {
      assert.equal(e.sql, f.sql, f.name)
    }
  }
}

test("the versioned fold table is the frozen search_map.tsv, and its sha256 is the live database's", () => {
  // The TSV is the searchText of before, frozen: the sha256 is the one the old fold's table had.
  const file = readFileSync(join(ROOT, "db", "Schema", "search_map.tsv"), "utf8")
  assert.equal(sha256(file), SEARCH_MAP_SHA256)
  const lines = file.split("\n").slice(0, -1)
  assert.equal(lines.length, 2299)
  for (const line of lines) assert.match(line, /^[0-9a-f]{4}\t([0-9a-f]{4,5}( [0-9a-f]{4,5})*)?$/, line)
})

test("a new file migrates to the schema and the search_map the JS migrations make", (t) => {
  const bin = tempDb(t)
  sync(bin)
  masterHolds(bin, S.newFile.master)
  assert.ok(rows(bin, "PRAGMA user_version")[0].user_version >= S.newFile.userVersion)
  assert.equal(S.newFile.userVersion, S.version)
  assert.equal(sha256(foldTable(bin)), SEARCH_MAP_SHA256)
  assert.deepEqual(projectedRows(rows(bin, "SELECT * FROM settings"), S.newFile.settings), S.newFile.settings)
  assert.equal(cli(bin, "PRAGMA journal_mode").trim(), "delete", "the binary never turns WAL on")
})

test("test/lib/v0.sql is the first migration of before the binary, statement for statement", () => {
  assert.deepEqual(V0_SCHEMA.trim().split(";\n").map((s) => s.replace(/;$/, "")), S.firstMigration)
})

test("a v0 file with rows migrates to the rows the JS migrations leave", (t) => {
  const bin = v0Db(t)
  const res = call(bin, { sync: { since: -1, views: [] } })
  assert.ok(res.snapshot)
  masterHolds(bin, S.v0WithRows.master)
  assert.ok(rows(bin, "PRAGMA user_version")[0].user_version >= S.v0WithRows.userVersion)
  assert.deepEqual(Object.keys(S.v0WithRows.tables), ["items", "history", "alarms", "settings", "sqlite_sequence"])
  for (const [table, frozen] of Object.entries(S.v0WithRows.tables)) {
    const live = rows(bin, `SELECT * FROM ${table} ORDER BY 1`)
    const kept = table === "sqlite_sequence" ? live.filter((row) => frozen.some((f) => f.name === row.name)) : live
    assert.deepEqual(projectedRows(kept, frozen), frozen, table)
  }
  assert.equal(sha256(foldTable(bin)), SEARCH_MAP_SHA256)
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
  assert.equal(runs.filter((r) => /migrated 0 -> \d+\n/.test(r.err)).length, 1, runs.map((r) => r.err).join("|"))
  assert.equal(rows(path, "SELECT count(*) AS n FROM search_map")[0].n, 2299)
  assert.equal(rows(path, "SELECT count(*) AS n FROM items")[0].n, 6)
  assert.equal(rows(path, "SELECT count(*) AS n FROM settings")[0].n, 1)
})
