// The fixture of the omanotes-db tests: the committed binary for this machine,
// driven over its wire, and the sqlite3 CLI as the oracle and as someone
// editing the file by hand. data/Db.js still builds the SQL of today, so a
// parity test runs that SQL on one copy of a database and the binary on the
// other and compares the tables.
import assert from "node:assert/strict"
import { spawn, spawnSync } from "node:child_process"
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs"
import { machine, tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { DB_JS, NAMES, T0, V0_SCHEMA, seed, start, dbAt } from "./db-fixture.mjs"
import { loadQmlLib } from "./load-qml-lib.mjs"

export { T0, V0_SCHEMA }
export const Db = loadQmlLib(DB_JS, [...NAMES, "searchText"])

export const ROOT = new URL("../../", import.meta.url).pathname
// The file suffix is `uname -m`, the rule the QML and update.sh use.
// OMANOTES_DB_BIN points the suite at another build, to see a test fail on a planted defect.
export const BIN = process.env.OMANOTES_DB_BIN ?? join(ROOT, "bin", "omanotes-db." + machine())
export const BUILD = JSON.parse(readFileSync(join(ROOT, "bin", "BUILD.json"), "utf8"))
export const PROTOCOL = String(BUILD.protocol[1])

// The last line of stderr, which the binary makes {"err","detail"} on exit 1, 64 and 70.
export function lastError(stderr) {
  const lines = String(stderr).trim().split("\n")
  return JSON.parse(lines[lines.length - 1])
}

// Any argv, the request as bytes or as an object; env is empty, as the QML
// spawns it (clearEnvironment).
export function exec(args, input = "", { env = {} } = {}) {
  const body = typeof input === "string" || Buffer.isBuffer(input) ? input : JSON.stringify(input)
  const r = spawnSync(BIN, args, { input: body, env, maxBuffer: 1 << 28 })
  if (r.error) throw r.error
  return { status: r.status, signal: r.signal, stdout: r.stdout.toString("utf8"), stderr: r.stderr.toString("utf8") }
}

// One `run` request. On exit 0 the parsed response; on anything else the
// failure, and stdout must be empty then.
export function call(dbPath, request, opts = {}) {
  const r = exec([PROTOCOL, "run", dbPath], request, opts)
  if (r.status !== 0) {
    assert.equal(r.stdout, "", "stdout carries nothing unless the exit is 0")
    return { status: r.status, error: lastError(r.stderr), stderr: r.stderr }
  }
  return JSON.parse(r.stdout)
}

export function write(op, args = {}, { by = "widget", id = 1, at = T0 } = {}) {
  return { id, by, op, at, args }
}

// One write, its result.
export function run(dbPath, op, args, opts = {}) {
  const res = call(dbPath, { writes: [write(op, args, opts)] })
  assert.ok(res.results, JSON.stringify(res))
  return res.results[0]
}

export function sync(dbPath, since = -1, views = []) {
  const res = call(dbPath, { sync: { since, views } })
  assert.ok(res.snapshot, JSON.stringify(res))
  return res.snapshot
}

export function tempDir(t) {
  const dir = mkdtempSync(join(tmpdir(), "omanotes-bin-"))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  return dir
}

export function tempDb(t) {
  return join(tempDir(t), "omarchy", "scratchpad.db")
}

// The CLI, as the oracle and as a hand edit. -init /dev/null keeps the user's sqliterc out.
export function cli(dbPath, sql, { json = false } = {}) {
  const args = ["-init", "/dev/null"]
  if (json) args.push("-json")
  args.push(dbPath, ".timeout 5000", ...(Array.isArray(sql) ? sql : [sql]))
  const r = spawnSync("sqlite3", args, { encoding: "utf8" })
  assert.equal(r.status, 0, r.stderr)
  return r.stdout
}

export function rows(dbPath, sql) {
  return Db.parseRows(cli(dbPath, sql, { json: true }))
}

// A database as today's JS leaves it: the v0 schema, the seed rows, then
// migrateSql through the CLI (test/lib/db-fixture.mjs start).
export function legacyDb(t) {
  const path = v0Db(t)
  start(path)
  return path
}

// A file today's JS creates from nothing.
export function legacyNewDb(t) {
  const path = tempDb(t)
  start(path)
  return path
}

// The same bytes twice: the old SQL runs on `old`, the binary on `bin`.
export function pair(t) {
  const old = legacyDb(t)
  const bin = old.replace("scratchpad.db", "scratchpad-bin.db")
  copyFileSync(old, bin)
  return { old, bin }
}

// A v0 file with the seed rows, before any migration: the live database before versioning.
export function v0Db(t) {
  const path = tempDb(t)
  mkdirSync(dirname(path), { recursive: true })
  assert.equal(spawnSync("sqlite3", [path, V0_SCHEMA]).status, 0)
  seed(dbAt(path))
  return path
}

// Holds a lock with a sqlite3 process until release() is awaited. `mode` is
// IMMEDIATE (other readers go on) or EXCLUSIVE (nobody reads).
export async function holdLock(dbPath, mode) {
  const child = spawn("sqlite3", ["-init", "/dev/null", dbPath], { stdio: ["pipe", "pipe", "pipe"] })
  const locked = new Promise((resolve, reject) => {
    let out = ""
    child.stdout.on("data", (d) => {
      out += d
      if (out.includes("locked")) resolve()
    })
    child.on("exit", (code) => reject(new Error("sqlite3 exited " + code)))
  })
  child.stdin.write(`BEGIN ${mode};\nSELECT count(*) FROM sqlite_schema;\n.print locked\n`)
  await locked
  return async () => {
    const done = new Promise((resolve) => child.on("close", resolve))
    child.stdin.end("COMMIT;\n.quit\n")
    await done
  }
}

// Every table a write can touch, as the CLI reads it.
export const TABLES = {
  items: "SELECT * FROM items ORDER BY id",
  history: "SELECT * FROM history ORDER BY id",
  alarms: "SELECT * FROM alarms ORDER BY id",
  settings: "SELECT * FROM settings ORDER BY id",
  sequence: "SELECT * FROM sqlite_sequence ORDER BY name"
}

export function sameTables(a, b, label) {
  for (const [name, sql] of Object.entries(TABLES)) {
    assert.deepEqual(rows(b, sql), rows(a, sql), `${label}: ${name}`)
  }
}
