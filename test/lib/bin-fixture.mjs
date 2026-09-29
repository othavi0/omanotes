// The fixture of the database tests: the committed binary for this machine,
// driven over its wire, data/Db.js as the plugin runs it, and the sqlite3 CLI
// as the oracle and as someone editing the file by hand. test/fixtures/parity/
// holds what the SQL of before the binary left and read, so a parity test runs
// the binary and compares the tables with the frozen ones.
import assert from "node:assert/strict"
import { spawn, spawnSync } from "node:child_process"
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs"
import { machine, tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { loadQmlLib } from "./load-qml-lib.mjs"

export const Db = loadQmlLib(new URL("../../data/Db.js", import.meta.url), [
  "PROTOCOL", "MAX_REQUEST_BYTES", "now", "wholeId", "wholeIn", "daysMask", "maskDays", "alarmCells", "clampedInt",
  "parseAlarms", "mergeAlarms", "SETTINGS", "settingsCells", "parseSettings", "mergeSettings", "parseCounts", "prunes",
  "movedRows", "typeRows", "matchedRows", "wellFormed", "request", "utf8Length", "command", "reply", "ERROR_TEXT", "errorText",
  "MAX_WRITE_BYTES", "MAX_QUERY", "viewQuery", "sameRows", "writeJson", "definitive"
])

export const T0 = 1700000000
// The schema every database had before it was versioned, frozen. The comment
// lines go: the CLI reads an argument that starts with "--" as an option.
export const V0_SCHEMA = readFileSync(new URL("./v0.sql", import.meta.url), "utf8").replace(/^--.*\n/gm, "")

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

// One `run` request, as { results, snapshot }: stdout is one line per write,
// its result, then the snapshot (protocol 2, ADR-0020). On exit 3 the snapshot
// failed after the results went out: { status: 3, results, syncErr } from
// stderr's last line. On any other failure the error, and stdout must be empty
// then.
export function call(dbPath, request, opts = {}) {
  return answerOf(exec([PROTOCOL, "run", dbPath], request, opts), writesOf(request))
}

export function writesOf(request) {
  return typeof request === "object" && !Buffer.isBuffer(request) ? (request.writes ?? []).length : 0
}

// The answer of a finished `run` of `writes` writes, { status, stdout, stderr },
// as call() gives it. On exit 0 every line is whole; on exit 3 the snapshot
// line after the results may be cut.
export function answerOf(r, writes) {
  if (r.status === 0 || r.status === 3) {
    if (r.status === 0) assert.ok(r.stdout === "" || r.stdout.endsWith("\n"), "the last line is whole")
    const lines = r.stdout.split("\n").slice(0, -1)
    assert.ok(lines.length >= writes, `one whole line per write: ${r.stdout.slice(0, 200)}`)
    const results = lines.slice(0, writes).map((line) => JSON.parse(line))
    if (r.status === 3) return { status: 3, results, syncErr: lastError(r.stderr).syncErr, stderr: r.stderr }
    const res = { results }
    if (lines.length > writes) res.snapshot = JSON.parse(lines[writes])
    assert.ok(lines.length <= writes + 1, "nothing after the snapshot")
    return res
  }
  assert.equal(r.stdout, "", "stdout carries nothing unless the exit is 0 or 3")
  return { status: r.status, error: lastError(r.stderr), stderr: r.stderr }
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

// The rows of `sqlite3 -json`, which prints nothing for no rows.
export function rows(dbPath, sql) {
  const text = cli(dbPath, sql, { json: true }).trim()
  if (text === "") return []
  const parsed = JSON.parse(text)
  assert.ok(Array.isArray(parsed), "sqlite3 -json prints an array")
  return parsed
}

// A file the binary created from nothing.
export function newDb(t) {
  const path = tempDb(t)
  sync(path)
  return path
}

// The seed rows as the live database has them: written before versioning,
// then migrated by the binary.
export function seeded(t) {
  const path = v0Db(t)
  sync(path)
  return path
}

// A v0 file, before any migration: the live database before versioning. With
// `withSeed` it holds the seed rows.
export function v0Db(t, { withSeed = true } = {}) {
  const path = tempDb(t)
  mkdirSync(dirname(path), { recursive: true })
  cli(path, V0_SCHEMA)
  if (withSeed) cli(path, SEED)
  return path
}

const SEED = "INSERT INTO items (id, type, title, body, status, created_at, updated_at) VALUES"
  + " (1, 'note', 'Ideas for the panel', 'Tabs the same width', 0, " + (T0 - 3600) + ", " + (T0 - 3600) + "),"
  + " (2, 'todo', 'Renew the domain', 'Due day 30', 0, " + (T0 - 720) + ", " + (T0 - 720) + "),"
  + " (3, 'todo', 'Reply to upstream PR review', NULL, 0, " + (T0 - 10800) + ", " + (T0 - 10800) + "),"
  + " (4, 'note', 'Buy coffee', 'Medium grind', 1, " + (T0 - 90000) + ", " + (T0 - 90000) + "),"
  + " (5, 'todo', 'Backup scratchpad.db', NULL, 1, " + (T0 - 172800) + ", " + (T0 - 60) + ");"
  + " INSERT INTO history (id, type, title, action, ts) VALUES"
  + " (1, 'todo', 'Renew the domain', 'added', " + (T0 - 720) + "),"
  + " (2, 'note', 'Buy coffee', 'completed', " + (T0 - 90000) + "),"
  + " (3, 'todo', 'Old errand', 'deleted', " + (T0 - 100000) + ");"

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

// What the SQL of before the binary left and read, frozen in test/fixtures/parity/.
export function fixture(name) {
  return JSON.parse(readFileSync(new URL("../fixtures/parity/" + name, import.meta.url), "utf8"))
}

// Every table of `dbPath` equal to `expected`, a frozen { items, history, … }.
export function tablesAre(dbPath, expected, label) {
  assert.deepEqual(Object.keys(expected), Object.keys(TABLES), `${label}: the frozen tables`)
  for (const [name, sql] of Object.entries(TABLES)) {
    assert.deepEqual(rows(dbPath, sql), expected[name], `${label}: ${name}`)
  }
}

// The search fold of before the binary, one UTF-16 unit at a time, read from
// db/Schema/search_map.tsv: the table holds every unit the old fold changed,
// and bin-schema.test.mjs pins its sha256.
const FOLD = new Map(readFileSync(join(ROOT, "db", "Schema", "search_map.tsv"), "utf8").split("\n").filter((line) => line !== "").map((line) => {
  const [unit, folded] = line.split("\t")
  // A combining mark folds to nothing, an empty second field.
  const units = folded === "" ? [] : folded.split(" ")
  return [String.fromCharCode(parseInt(unit, 16)), units.map((h) => String.fromCodePoint(parseInt(h, 16))).join("")]
}))

export function fold(text) {
  return String(text).replace(/[\s\S]/g, (c) => FOLD.get(c) ?? c)
}
