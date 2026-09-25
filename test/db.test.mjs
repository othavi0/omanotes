import { test } from "node:test"
import assert from "node:assert/strict"
import { spawn as spawnAsync, spawnSync } from "node:child_process"
import { once } from "node:events"
import { setTimeout as sleep } from "node:timers/promises"
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { loadQmlLib } from "./lib/load-qml-lib.mjs"

const DB_JS = new URL("../data/Db.js", import.meta.url)
const NAMES = [
  "q", "likeEscape", "now", "listSql", "countsSql", "addSql", "setStatusSql",
  "updateSql", "deleteItemSql", "convertTypeSql", "historySql", "deleteHistorySql",
  "clearHistorySql", "sqliteCommand", "initCommand", "MIGRATIONS", "migrateSql",
  "parseVersion", "migrationRaced", "parseRows", "parseCounts", "parseId", "parseFound",
  "errorText", "moveSql", "movedRows"
]
const Db = loadQmlLib(DB_JS, NAMES)

// The schema every database had before it was versioned, as the live one
// still has it at user_version 0.
const V0_SCHEMA = "CREATE TABLE IF NOT EXISTS items ("
  + "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
  + "  type TEXT NOT NULL,"
  + "  title TEXT NOT NULL,"
  + "  body TEXT,"
  + "  status INTEGER NOT NULL DEFAULT 0,"
  + "  created_at INTEGER NOT NULL,"
  + "  updated_at INTEGER NOT NULL"
  + ");"
  + "CREATE INDEX IF NOT EXISTS idx_items_sort ON items(status, updated_at DESC);"
  + "CREATE INDEX IF NOT EXISTS idx_items_type_status ON items(type, status);"
  + "CREATE TABLE IF NOT EXISTS history ("
  + "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
  + "  type TEXT NOT NULL,"
  + "  title TEXT NOT NULL,"
  + "  action TEXT NOT NULL,"
  + "  ts INTEGER NOT NULL"
  + ");"
  + "CREATE INDEX IF NOT EXISTS idx_history_ts ON history(ts DESC);"

const T0 = 1700000000

function atT0(fn) {
  const real = Date.now
  Date.now = () => T0 * 1000
  try {
    return fn()
  } finally {
    Date.now = real
  }
}

function spawn(argv, env) {
  const r = spawnSync(argv[0], argv.slice(1), { encoding: "utf8", env })
  if (r.error) throw r.error
  return r
}

// Start-up as Db.qml runs it: read the version, then migrate from it.
function start(path, env, lib = Db) {
  const read = spawn(lib.initCommand(dirname(path), path), env)
  assert.equal(read.status, 0, read.stderr)
  const sql = lib.migrateSql(lib.parseVersion(read.stdout))
  if (sql.length === 0) return
  const migrate = spawn(lib.sqliteCommand(path, sql, false), env)
  assert.equal(migrate.status, 0, migrate.stderr)
}

function tempPath(t) {
  const dir = mkdtempSync(join(tmpdir(), "omanotes-db-"))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  return join(dir, "omarchy", "scratchpad.db")
}

// A throwaway database made by start-up and driven through sqliteCommand, the
// same argv Db.qml hands to Process.
function openDb(t, env) {
  const path = tempPath(t)
  start(path, env)
  return dbAt(path, env)
}

// A database as the live one is before versioning: the old schema, at version 0.
function openV0Db(t, env) {
  const path = tempPath(t)
  mkdirSync(dirname(path))
  assert.equal(spawn(["sqlite3", path, V0_SCHEMA]).status, 0)
  return dbAt(path, env)
}

function dbAt(path, env) {
  const db = {
    path,
    run(sql, json) {
      return spawn(Db.sqliteCommand(path, sql, json), env)
    },
    read(sql) {
      const r = db.run(sql, true)
      assert.equal(r.status, 0, r.stderr)
      return Db.parseRows(r.stdout)
    },
    write(sql) {
      const r = db.run(sql, false)
      assert.equal(r.status, 0, r.stderr)
      return r.stdout
    },
    item(id) {
      return db.read("SELECT * FROM items WHERE id = " + id)[0]
    },
    history() {
      return db.read("SELECT id, type, title, action, ts FROM history ORDER BY id")
    },
    snapshot() {
      return { items: db.read("SELECT * FROM items ORDER BY id"), history: db.history() }
    },
    version() {
      return db.read("PRAGMA user_version")[0].user_version
    },
    bytes() {
      return readFileSync(path)
    }
  }
  return db
}

function seed(db) {
  db.write("INSERT INTO items (id, type, title, body, status, created_at, updated_at) VALUES"
    + " (1, 'note', 'Ideas for the panel', 'Tabs the same width', 0, " + (T0 - 3600) + ", " + (T0 - 3600) + "),"
    + " (2, 'todo', 'Renew the domain', 'Due day 30', 0, " + (T0 - 720) + ", " + (T0 - 720) + "),"
    + " (3, 'todo', 'Reply to upstream PR review', NULL, 0, " + (T0 - 10800) + ", " + (T0 - 10800) + "),"
    + " (4, 'note', 'Buy coffee', 'Medium grind', 1, " + (T0 - 90000) + ", " + (T0 - 90000) + "),"
    + " (5, 'todo', 'Backup scratchpad.db', NULL, 1, " + (T0 - 172800) + ", " + (T0 - 60) + ");"
    + " INSERT INTO history (id, type, title, action, ts) VALUES"
    + " (1, 'todo', 'Renew the domain', 'added', " + (T0 - 720) + "),"
    + " (2, 'note', 'Buy coffee', 'completed', " + (T0 - 90000) + "),"
    + " (3, 'todo', 'Old errand', 'deleted', " + (T0 - 100000) + ");")
  return db
}

// The seeded rows as the live database has them: written before a start-up,
// which then migrates them to the current version.
function seeded(t, env) {
  const db = seed(openV0Db(t, env))
  start(db.path, env)
  return db
}

function ids(rows) {
  return rows.map((r) => r.id)
}

// The order the list showed before items had a position.
function byRecency(a, b) {
  return a.status - b.status || b.updated_at - a.updated_at || b.id - a.id
}

// Items from before the search copy and the position, as start-up leaves
// them. The seeded texts are plain ASCII, so the copy is the text in lower
// case, and each block is numbered from 1 in the order the list showed.
function migrated(items) {
  const shown = [...items].sort(byRecency)
  return items.map((item) => ({
    search_title: item.title.toLowerCase(),
    search_body: item.body === null ? null : item.body.toLowerCase(),
    position: shown.filter((other) => other.status === item.status).indexOf(item) + 1,
    ...item
  }))
}

const TABLES = "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('items', 'history') ORDER BY name"

test("start-up on a missing database creates the data dir, both tables and the current version", (t) => {
  const db = openDb(t)
  assert.deepEqual(db.read(TABLES).map((r) => r.name), ["history", "items"])
  assert.equal(db.version(), Db.MIGRATIONS.length)
})

test("start-up takes a version 0 database with rows to the current version and keeps every row", (t) => {
  const db = seed(openV0Db(t))
  assert.equal(db.version(), 0)
  const before = db.snapshot()
  start(db.path)
  assert.equal(db.version(), Db.MIGRATIONS.length)
  assert.deepEqual(db.snapshot(), { items: migrated(before.items), history: before.history })
})

test("a second start-up changes nothing", (t) => {
  const db = seed(openV0Db(t))
  start(db.path)
  const bytes = db.bytes()
  assert.deepEqual(Db.migrateSql(Db.MIGRATIONS.length), [])
  start(db.path)
  assert.deepEqual(db.bytes(), bytes)
})

test("a database newer than this Omanotes is left as it is", () => {
  assert.deepEqual(Db.migrateSql(Db.MIGRATIONS.length + 1), [])
})

test("a migration appended to MIGRATIONS runs once, on the databases below its version", (t) => {
  const Next = loadQmlLib(DB_JS, NAMES)
  Next.MIGRATIONS.push(["ALTER TABLE items ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0"])
  for (const db of [seed(openV0Db(t)), seeded(t)]) {
    const before = db.snapshot()
    start(db.path, undefined, Next)
    assert.equal(db.version(), Db.MIGRATIONS.length + 1)
    assert.deepEqual(db.snapshot(), {
      items: migrated(before.items).map((item) => ({ ...item, pinned: 0 })),
      history: before.history
    })
    const bytes = db.bytes()
    start(db.path, undefined, Next)
    assert.deepEqual(db.bytes(), bytes)
  }
})

test("a migration built from a version another start-up already moved writes nothing", (t) => {
  const Next = loadQmlLib(DB_JS, NAMES)
  Next.MIGRATIONS.push(["ALTER TABLE items ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0"])
  const db = seed(openV0Db(t))
  const stale = Next.migrateSql(0)
  start(db.path, undefined, Next)
  const bytes = db.bytes()
  const r = db.run(stale, false)
  assert.notEqual(r.status, 0)
  assert.equal(Db.migrationRaced(r.stderr), true)
  assert.deepEqual(db.bytes(), bytes)
})

test("migrationRaced is false for any other failure", (t) => {
  const r = openDb(t).run("UPDATE items SET nope = 1", false)
  assert.equal(Db.migrationRaced(r.stderr), false)
  assert.equal(Db.migrationRaced("Error: database is locked\n"), false)
})

test("parseVersion: the integer PRAGMA user_version prints", () => {
  assert.equal(Db.parseVersion("3\n"), 3)
  assert.throws(() => Db.parseVersion(""), { message: "unreadable sqlite3 output" })
  assert.throws(() => Db.parseVersion("x"), { message: "unreadable sqlite3 output" })
})

// Starts argv while another process holds an exclusive lock on path, releases
// the lock 300 ms later, and resolves with how argv exited.
async function runWhileLocked(t, path, argv) {
  const holder = spawnAsync("sqlite3", [path], { stdio: ["pipe", "ignore", "ignore"] })
  t.after(() => holder.kill())
  holder.stdin.write("BEGIN EXCLUSIVE;\n")
  while (spawn(["sqlite3", path, "SELECT 1"]).status === 0) await sleep(10)

  const run = spawnAsync(argv[0], argv.slice(1), { stdio: ["ignore", "ignore", "pipe"] })
  const exited = once(run, "close")
  let stderr = ""
  run.stderr.on("data", (chunk) => { stderr += chunk })
  await sleep(300)
  holder.stdin.end("COMMIT;\n")
  const [status] = await exited
  return { status, stderr }
}

test("start-up waits for a lock held by another process", { timeout: 10000 }, async (t) => {
  const db = seed(openV0Db(t))
  const read = await runWhileLocked(t, db.path, Db.initCommand(dirname(db.path), db.path))
  assert.equal(read.status, 0, read.stderr)
  const migrate = await runWhileLocked(t, db.path, Db.sqliteCommand(db.path, Db.migrateSql(0), false))
  assert.equal(migrate.status, 0, migrate.stderr)
  assert.equal(db.version(), Db.MIGRATIONS.length)
})

test("sqliteCommand: a write waits for a lock held by another process", { timeout: 10000 }, async (t) => {
  const db = seeded(t)
  const { status, stderr } = await runWhileLocked(t, db.path, Db.sqliteCommand(db.path, Db.deleteHistorySql(1), false))
  assert.equal(status, 0, stderr)
  assert.deepEqual(ids(db.history()), [2, 3])
})

test("listSql: all items, status 0 (unread or pending) first, then each block in its order", (t) => {
  const db = seeded(t)
  assert.deepEqual(ids(db.read(Db.listSql("all", ""))), [2, 1, 3, 5, 4])
})

function order(db, filterType = "all") {
  return ids(db.read(Db.listSql(filterType, "")))
}

function positions(db, status) {
  return db.read("SELECT id, position FROM items WHERE status = " + status + " ORDER BY position")
}

test("the migration numbers each block in the order the list showed, the newest id first on a tie", (t) => {
  const db = seed(openV0Db(t))
  db.write("INSERT INTO items (id, type, title, body, status, created_at, updated_at) VALUES"
    + " (6, 'note', 'Same second as 2', NULL, 0, " + (T0 - 720) + ", " + (T0 - 720) + "),"
    + " (7, 'todo', 'Same second as 4', NULL, 1, " + (T0 - 90000) + ", " + (T0 - 90000) + ")")
  const shown = ids(db.read("SELECT id FROM items ORDER BY status ASC, updated_at DESC, id DESC"))
  start(db.path)
  assert.deepEqual(order(db), shown)
  assert.deepEqual(order(db), [6, 2, 1, 3, 5, 7, 4])
  assert.deepEqual(positions(db, 0), [{ id: 6, position: 1 }, { id: 2, position: 2 }, { id: 1, position: 3 }, { id: 3, position: 4 }])
  assert.deepEqual(positions(db, 1), [{ id: 5, position: 1 }, { id: 7, position: 2 }, { id: 4, position: 3 }])
})

test("addSql puts a new item at the top of the first block, whatever the other items' times", (t) => {
  const db = seeded(t)
  db.write("UPDATE items SET updated_at = " + (T0 + 100) + " WHERE id = 2")
  const id = Db.parseId(db.write(atT0(() => Db.addSql("note", "Buy milk", ""))))
  assert.deepEqual(order(db), [id, 2, 1, 3, 5, 4])
  const other = Db.parseId(db.write(atT0(() => Db.addSql("todo", "Call the bank", ""))))
  assert.deepEqual(order(db), [other, id, 2, 1, 3, 5, 4])
})

test("addSql puts a new item above items reopened before it", (t) => {
  const db = seeded(t)
  db.write(atT0(() => Db.setStatusSql(5, 0)))
  db.write(atT0(() => Db.setStatusSql(4, 0)))
  const id = Db.parseId(db.write(atT0(() => Db.addSql("note", "Buy milk", ""))))
  assert.deepEqual(order(db), [id, 4, 5, 2, 1, 3])
})

test("setStatusSql: a read or completed item goes to the top of the second block, a reopened one to the top of the first", (t) => {
  const db = seeded(t)
  db.write(Db.moveSql(4, 5, false))
  assert.deepEqual(order(db), [2, 1, 3, 4, 5])
  db.write(atT0(() => Db.setStatusSql(3, 1)))
  assert.deepEqual(order(db), [2, 1, 3, 4, 5])
  assert.deepEqual(ids(positions(db, 1)), [3, 4, 5])
  db.write(atT0(() => Db.setStatusSql(5, 0)))
  assert.deepEqual(order(db), [5, 2, 1, 3, 4])
  db.write(atT0(() => Db.setStatusSql(1, 1)))
  assert.deepEqual(order(db), [5, 2, 1, 3, 4])
  assert.deepEqual(ids(positions(db, 1)), [1, 3, 4])
})

test("setStatusSql: setting the status an item already has leaves it in place", (t) => {
  const db = seeded(t)
  db.write(Db.moveSql(3, 2, false))
  db.write(atT0(() => Db.setStatusSql(1, 0)))
  db.write(atT0(() => Db.setStatusSql(4, 1)))
  assert.deepEqual(order(db), [3, 2, 1, 5, 4])
})

test("updateSql and convertTypeSql leave an item where it is", (t) => {
  const db = seeded(t)
  const before = db.read("SELECT id, position FROM items ORDER BY id")
  db.write(atT0(() => Db.updateSql(3, "Answer the review", "by Friday")))
  db.write(atT0(() => Db.convertTypeSql(3)))
  db.write(atT0(() => Db.updateSql(4, "Buy tea", "")))
  db.write(atT0(() => Db.convertTypeSql(4)))
  assert.deepEqual(order(db), [2, 1, 3, 5, 4])
  assert.deepEqual(db.read("SELECT id, position FROM items ORDER BY id"), before)
})

test("moveSql: puts an item just before or just after another of its block", (t) => {
  const db = seeded(t)
  assert.equal(Db.parseFound(db.write(Db.moveSql(3, 2, false))), true)
  assert.deepEqual(order(db), [3, 2, 1, 5, 4])
  db.write(Db.moveSql(3, 1, true))
  assert.deepEqual(order(db), [2, 1, 3, 5, 4])
  db.write(Db.moveSql(2, 3, true))
  assert.deepEqual(order(db), [1, 3, 2, 5, 4])
  db.write(Db.moveSql(4, 5, false))
  assert.deepEqual(order(db), [1, 3, 2, 4, 5])
})

test("moveSql: renumbers only the item's block and changes nothing else", (t) => {
  const db = seeded(t)
  const before = db.snapshot()
  db.write(Db.moveSql(3, 2, false))
  assert.deepEqual(positions(db, 0), [{ id: 3, position: 1 }, { id: 2, position: 2 }, { id: 1, position: 3 }])
  const after = db.snapshot()
  assert.deepEqual(after.history, before.history)
  const strip = (items) => items.map(({ position, ...rest }) => rest)
  assert.deepEqual(strip(after.items), strip(before.items))
  assert.deepEqual(after.items.filter((i) => i.status === 1), before.items.filter((i) => i.status === 1))
})

test("moveSql: a move across the two blocks, onto the item itself or with a missing id writes nothing", (t) => {
  const db = seeded(t)
  const before = db.snapshot()
  for (const sql of [Db.moveSql(5, 2, false), Db.moveSql(2, 4, true), Db.moveSql(2, 2, false),
    Db.moveSql(99, 2, false), Db.moveSql(2, 99, true)]) {
    assert.equal(Db.parseFound(db.write(sql)), false)
    assert.deepEqual(db.snapshot(), before)
  }
})

test("moveSql: a move among the notes keeps the todos where they were", (t) => {
  const db = seeded(t)
  const note = Db.parseId(db.write(atT0(() => Db.addSql("note", "Buy milk", ""))))
  assert.deepEqual(order(db), [note, 2, 1, 3, 5, 4])
  assert.deepEqual(order(db, "note"), [note, 1, 4])
  db.write(Db.moveSql(1, note, false))
  assert.deepEqual(order(db, "note"), [1, note, 4])
  assert.deepEqual(order(db), [1, note, 2, 3, 5, 4])
  db.write(Db.moveSql(1, note, true))
  assert.deepEqual(order(db), [note, 1, 2, 3, 5, 4])
  db.write(Db.moveSql(note, 1, true))
  assert.deepEqual(order(db), [1, note, 2, 3, 5, 4])
  assert.deepEqual(order(db, "todo"), [2, 3, 5])
})

test("movedRows: the list with the item moved before or after another, the same list when either is missing", () => {
  const rows = [{ id: 1 }, { id: 2 }, { id: 3 }, { id: 4 }]
  assert.deepEqual(ids(Db.movedRows(rows, 3, 1, false)), [3, 1, 2, 4])
  assert.deepEqual(ids(Db.movedRows(rows, 1, 3, true)), [2, 3, 1, 4])
  assert.deepEqual(ids(Db.movedRows(rows, "4", "2", true)), [1, 2, 4, 3])
  assert.deepEqual(ids(Db.movedRows(rows, 9, 1, false)), [1, 2, 3, 4])
  assert.deepEqual(ids(Db.movedRows(rows, 1, 9, false)), [1, 2, 3, 4])
  assert.deepEqual(ids(rows), [1, 2, 3, 4])
})

test("listSql: type filter", (t) => {
  const db = seeded(t)
  assert.deepEqual(ids(db.read(Db.listSql("todo", ""))), [2, 3, 5])
  assert.deepEqual(ids(db.read(Db.listSql("note", ""))), [1, 4])
})

test("listSql: an invalid filter lists every item", (t) => {
  const db = seeded(t)
  assert.deepEqual(ids(db.read(Db.listSql("bogus", ""))), [2, 1, 3, 5, 4])
  assert.deepEqual(ids(db.read(Db.listSql("note' OR 1=1 --", ""))), [2, 1, 3, 5, 4])
})

test("listSql: search matches title or body and ignores ASCII case", (t) => {
  const db = seeded(t)
  assert.deepEqual(ids(db.read(Db.listSql("all", "DOMAIN"))), [2])
  assert.deepEqual(ids(db.read(Db.listSql("all", "grind"))), [4])
  assert.deepEqual(ids(db.read(Db.listSql("note", "domain"))), [])
  assert.deepEqual(ids(db.read(Db.listSql("all", "   "))), [2, 1, 3, 5, 4])
})

function searchIds(db, filterType, query) {
  return ids(db.read(Db.listSql(filterType, query)))
}

// Every spelling of a word finds the item, whatever its case and accents, and
// an accent typed as a separate combining mark counts the same.
function assertAccentedSearch(db, titleId, bodyId) {
  for (const query of ["CAFÉ", "cafe", "Cafe", "café", "CAFE", "cafe\u0301"]) {
    assert.deepEqual(searchIds(db, "all", query), [titleId], query)
  }
  for (const query of ["AÇÃO", "ação", "acao", "Acao", "PÃO", "pao"]) {
    assert.deepEqual(searchIds(db, "all", query), [bodyId], query)
  }
  assert.deepEqual(searchIds(db, "todo", "cafe"), [])
  assert.deepEqual(searchIds(db, "all", "cafes"), [])
}

test("listSql: search ignores case and accents in items from before the migration", (t) => {
  const db = openV0Db(t)
  db.write("INSERT INTO items (id, type, title, body, status, created_at, updated_at) VALUES"
    + " (1, 'note', 'Café', NULL, 0, " + T0 + ", " + T0 + "),"
    + " (2, 'todo', 'Padaria', 'Revisar a AÇÃO do pão', 0, " + (T0 - 1) + ", " + (T0 - 1) + ")")
  start(db.path)
  assertAccentedSearch(db, 1, 2)
})

test("listSql: search ignores case and accents in items added or edited after it", (t) => {
  const db = seeded(t)
  const cafe = Db.parseId(db.write(atT0(() => Db.addSql("note", "Café", ""))))
  db.write(atT0(() => Db.updateSql(2, "Padaria", "Revisar a AÇÃO do pão")))
  assertAccentedSearch(db, cafe, 2)
  db.write(atT0(() => Db.updateSql(cafe, "Chá", "")))
  assert.deepEqual(searchIds(db, "all", "cafe"), [])
  assert.deepEqual(searchIds(db, "all", "CHA"), [cafe])
})

test("listSql: search finds items inserted or edited with sqlite3 after the migration", (t) => {
  const db = openDb(t)
  db.write(Db.addSql("note", "Buy milk", ""))
  db.write("INSERT INTO items (type, title, body, status, created_at, updated_at)"
    + " VALUES ('todo', 'Renew the domain', 'Pagar a AÇÃO', 0, " + T0 + ", " + T0 + ")")
  db.write("UPDATE items SET title = 'Call the bank' WHERE id = 1")
  assert.deepEqual(searchIds(db, "all", "domain"), [2])
  assert.deepEqual(searchIds(db, "all", "acao"), [2])
  assert.deepEqual(searchIds(db, "all", "CALL"), [1])
  assert.deepEqual(searchIds(db, "all", "milk"), [])
  db.write("UPDATE items SET body = 'Due day 30' WHERE id = 2")
  assert.deepEqual(searchIds(db, "all", "acao"), [])
  assert.deepEqual(searchIds(db, "all", "DUE"), [2])
})

// Every character of the Basic Multilingual Plane except NUL and the
// surrogate halves, plus combining marks, a final sigma and characters
// outside the plane, which the fold must treat the same in JS and SQL.
function searchSamples() {
  const samples = []
  let chunk = ""
  for (let u = 1; u < 0x10000; u++) {
    if (u >= 0xd800 && u <= 0xdfff) continue
    chunk += String.fromCharCode(u)
    if (chunk.length === 1024) {
      samples.push(chunk)
      chunk = ""
    }
  }
  samples.push(chunk, "", "Ὀδυσσεύς ΟΔΟΣ", "e\u0301 A\u030a \ud801\udc00\ud83d\ude00 İstanbul Ǆ ß ﬁ")
  return samples
}

function insertRaw(db, samples) {
  db.write(["BEGIN"].concat(samples.map((text, i) =>
    "INSERT INTO items (type, title, body, status, created_at, updated_at) VALUES ('note', "
      + Db.q(text) + ", " + (text === "" ? "NULL" : Db.q(text)) + ", 0, " + i + ", " + i + ")"), ["COMMIT"]))
}

test("the migration and sqlite3 writes fold items exactly as addSql does", (t) => {
  const samples = searchSamples()
  const added = openDb(t)
  for (const text of samples) added.write(Db.addSql("note", text, text))
  const copies = "SELECT title, body, search_title, search_body FROM items ORDER BY id"
  const expected = added.read(copies)

  const old = openV0Db(t)
  insertRaw(old, samples)
  start(old.path)
  assert.deepEqual(old.read(copies), expected, "migrated")

  const inserted = openDb(t)
  insertRaw(inserted, samples)
  assert.deepEqual(inserted.read(copies), expected, "inserted with sqlite3")

  const edited = openDb(t)
  insertRaw(edited, samples.map(() => "x"))
  edited.write(["BEGIN"].concat(samples.map((text, i) =>
    "UPDATE items SET title = " + Db.q(text) + ", body = " + (text === "" ? "NULL" : Db.q(text))
      + " WHERE id = " + (i + 1)), ["COMMIT"]))
  assert.deepEqual(edited.read(copies), expected, "edited with sqlite3")
})

test("listSql: a quote and LIKE wildcards in the search are matched literally", (t) => {
  const db = openDb(t)
  for (const title of ["it's 100% done", "it's 1000 done", "a\\b"]) db.write(Db.addSql("note", title, ""))
  assert.deepEqual(ids(db.read(Db.listSql("all", "it's 100%"))), [1])
  assert.deepEqual(ids(db.read(Db.listSql("all", "_"))), [])
  assert.deepEqual(ids(db.read(Db.listSql("all", "a\\b"))), [3])
})

test("countsSql: empty database counts zero", (t) => {
  const db = openDb(t)
  assert.deepEqual(db.read(Db.countsSql()), [{ unreadNotes: 0, pendingTodos: 0, notes: 0, todos: 0, history: 0 }])
})

test("countsSql: unread notes, pending todos and totals per type", (t) => {
  const db = seeded(t)
  assert.deepEqual(db.read(Db.countsSql()), [{ unreadNotes: 1, pendingTodos: 2, notes: 2, todos: 3, history: 3 }])
})

test("addSql: stores the item, prints its id and logs it as added", (t) => {
  const db = seeded(t)
  const id = Db.parseId(db.write(atT0(() => Db.addSql("todo", "Jane's list", "milk, 'eggs'"))))
  assert.equal(id, 6)
  assert.deepEqual(db.item(id), {
    id: 6, type: "todo", title: "Jane's list", body: "milk, 'eggs'", status: 0, position: 0, created_at: T0, updated_at: T0,
    search_title: "jane's list", search_body: "milk, 'eggs'"
  })
  assert.deepEqual(db.history().at(-1), { id: 4, type: "todo", title: "Jane's list", action: "added", ts: T0 })
})

test("addSql: an empty body is stored as NULL and an unknown type as a note", (t) => {
  const db = openDb(t)
  const id = Db.parseId(db.write(atT0(() => Db.addSql("bogus", "Buy milk", ""))))
  assert.equal(db.item(id).body, null)
  assert.equal(db.item(id).search_body, null)
  assert.equal(db.item(id).type, "note")
})

test("setStatusSql: completing a todo", (t) => {
  const db = seeded(t)
  db.write(atT0(() => Db.setStatusSql(2, 1)))
  assert.equal(db.item(2).status, 1)
  assert.equal(db.item(2).updated_at, T0)
  assert.deepEqual(db.history().at(-1), { id: 4, type: "todo", title: "Renew the domain", action: "completed", ts: T0 })
})

test("setStatusSql: marking a read note unread logs it as reopened", (t) => {
  const db = seeded(t)
  db.write(atT0(() => Db.setStatusSql(4, 0)))
  assert.equal(db.item(4).status, 0)
  assert.deepEqual(db.history().at(-1), { id: 4, type: "note", title: "Buy coffee", action: "reopened", ts: T0 })
})

test("setStatusSql: setting the status an item already has records nothing", (t) => {
  const db = seeded(t)
  const before = db.snapshot()
  assert.equal(Db.parseFound(db.write(atT0(() => Db.setStatusSql(4, 1)))), true)
  assert.equal(Db.parseFound(db.write(atT0(() => Db.setStatusSql(2, 0)))), true)
  assert.deepEqual(db.snapshot(), before)
})

for (const [name, build] of [
  ["setStatusSql", (id) => Db.setStatusSql(id, 1)],
  ["updateSql", (id) => Db.updateSql(id, "Renew the car", "x")],
  ["convertTypeSql", (id) => Db.convertTypeSql(id)],
  ["deleteItemSql", (id) => Db.deleteItemSql(id)]
]) {
  test(name + ": reports whether the item exists, and a missing id records nothing", (t) => {
    const db = seeded(t)
    const before = db.snapshot()
    assert.equal(Db.parseFound(db.write(atT0(() => build(99)))), false)
    assert.deepEqual(db.snapshot(), before)
    assert.equal(Db.parseFound(db.write(atT0(() => build(2)))), true)
    assert.notDeepEqual(db.snapshot(), before)
  })
}

test("sqliteCommand: the user's sqliterc does not change what reads and writes print", (t) => {
  const home = mkdtempSync(join(tmpdir(), "omanotes-home-"))
  t.after(() => rmSync(home, { recursive: true, force: true }))
  const rc = ".headers on\n.mode column\n"
  mkdirSync(join(home, "sqlite3"))
  writeFileSync(join(home, "sqlite3", "sqliterc"), rc)
  writeFileSync(join(home, ".sqliterc"), rc)
  const db = seeded(t, { ...process.env, HOME: home, XDG_CONFIG_HOME: home })

  assert.equal(Db.parseId(db.write(atT0(() => Db.addSql("todo", "Renew the car", "")))), 6)
  assert.equal(Db.parseFound(db.write(atT0(() => Db.setStatusSql(2, 1)))), true)
  assert.equal(Db.parseFound(db.write(atT0(() => Db.updateSql(3, "Answer the review", "")))), true)
  assert.equal(Db.parseFound(db.write(atT0(() => Db.convertTypeSql(1)))), true)
  assert.equal(Db.parseFound(db.write(atT0(() => Db.deleteItemSql(4)))), true)
  assert.equal(Db.parseFound(db.write(atT0(() => Db.setStatusSql(99, 1)))), false)
  assert.deepEqual(ids(db.read(Db.listSql("all", ""))), [6, 1, 3, 2, 5])
})

test("updateSql: new title and body, logged with the new title", (t) => {
  const db = seeded(t)
  db.write(atT0(() => Db.updateSql(3, "Answer the review", "by Friday")))
  const row = db.item(3)
  assert.deepEqual([row.title, row.body, row.updated_at, row.created_at], ["Answer the review", "by Friday", T0, T0 - 10800])
  assert.deepEqual(db.history().at(-1), { id: 4, type: "todo", title: "Answer the review", action: "edited", ts: T0 })
})

test("updateSql: an emptied body is stored as NULL", (t) => {
  const db = seeded(t)
  db.write(atT0(() => Db.updateSql(1, "Ideas for the panel", "")))
  assert.equal(db.item(1).body, null)
  assert.equal(db.item(1).search_body, null)
})

test("deleteItemSql: removes the item and logs its title", (t) => {
  const db = seeded(t)
  db.write(atT0(() => Db.deleteItemSql(4)))
  assert.equal(db.item(4), undefined)
  assert.deepEqual(ids(db.read(Db.listSql("all", ""))), [2, 1, 3, 5])
  assert.deepEqual(db.history().at(-1), { id: 4, type: "note", title: "Buy coffee", action: "deleted", ts: T0 })
})

test("convertTypeSql: flips the type, keeps the status and logs the new type", (t) => {
  const db = seeded(t)
  db.write(atT0(() => Db.convertTypeSql(4)))
  assert.deepEqual([db.item(4).type, db.item(4).status, db.item(4).updated_at], ["todo", 1, T0])
  assert.deepEqual(db.history().at(-1), { id: 4, type: "todo", title: "Buy coffee", action: "converted", ts: T0 })
  db.write(atT0(() => Db.convertTypeSql(4)))
  assert.equal(db.item(4).type, "note")
})

test("an id that is not a whole number is refused before any SQL is built", () => {
  for (const id of ["abc", "", "1.5", "-1", "2 OR 1=1", null, undefined, NaN, true]) {
    for (const build of [
      () => Db.setStatusSql(id, 1),
      () => Db.updateSql(id, "x", "y"),
      () => Db.deleteItemSql(id),
      () => Db.convertTypeSql(id),
      () => Db.deleteHistorySql(id),
      () => Db.moveSql(id, 1, false),
      () => Db.moveSql(1, id, true)
    ]) {
      assert.throws(build, { message: "invalid id: " + id })
    }
  }
})

test("a numeric id is accepted as a number or as digits", (t) => {
  const db = seeded(t)
  db.write(Db.deleteHistorySql("2"))
  db.write(Db.deleteHistorySql(3))
  assert.deepEqual(ids(db.history()), [1])
})

for (const [name, build, failOn] of [
  ["addSql", () => Db.addSql("todo", "Renew the car", ""), "INSERT ON history"],
  ["setStatusSql", () => Db.setStatusSql(2, 1), "UPDATE ON items"],
  ["updateSql", () => Db.updateSql(2, "Renew the car", "x"), "INSERT ON history"],
  ["convertTypeSql", () => Db.convertTypeSql(2), "INSERT ON history"],
  ["deleteItemSql", () => Db.deleteItemSql(2), "DELETE ON items"]
]) {
  test(name + ": a failing second change writes nothing", (t) => {
    const db = seeded(t)
    db.write("CREATE TRIGGER fail_second BEFORE " + failOn + " BEGIN SELECT RAISE(ABORT, 'forced'); END")
    const before = db.snapshot()
    const r = db.run(atT0(build), false)
    assert.notEqual(r.status, 0)
    assert.match(r.stderr, /forced/)
    assert.deepEqual(db.snapshot(), before)
  })
}

test("historySql: newest first, capped at 500 rows", (t) => {
  const db = seeded(t)
  assert.deepEqual(ids(db.read(Db.historySql())), [1, 2, 3])
  db.write("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 600)"
    + " INSERT INTO history (type, title, action, ts) SELECT 'note', 'bulk', 'added', " + T0 + " + i FROM n")
  const rows = db.read(Db.historySql())
  assert.equal(rows.length, 500)
  assert.equal(rows[0].ts, T0 + 600)
  assert.equal(rows[499].ts, T0 + 101)
})

test("deleteHistorySql removes one row, clearHistorySql all of them, items stay", (t) => {
  const db = seeded(t)
  db.write(Db.deleteHistorySql(2))
  assert.deepEqual(ids(db.history()), [1, 3])
  db.write(Db.clearHistorySql())
  assert.deepEqual(db.history(), [])
  assert.equal(db.read(Db.listSql("all", "")).length, 5)
})

test("now is Unix seconds, rounded down", () => {
  const real = Date.now
  Date.now = () => T0 * 1000 + 999
  try {
    assert.equal(Db.now(), T0)
  } finally {
    Date.now = real
  }
})

test("parseRows: empty text", () => {
  assert.deepEqual(Db.parseRows(""), [])
})

test("parseRows: valid json array", () => {
  assert.deepEqual(Db.parseRows('[{"a":1}]'), [{ a: 1 }])
})

test("parseRows: output that is not a JSON array is an error", () => {
  assert.throws(() => Db.parseRows("not json"), { message: "unreadable sqlite3 output" })
  assert.throws(() => Db.parseRows('{"a":1}'), { message: "unreadable sqlite3 output" })
})

test("errorText: sqlite3's own message, without its argument position", (t) => {
  const db = openDb(t)
  const r = db.run("UPDATE items SET nope = 1", false)
  assert.equal(Db.errorText(r.stderr, r.status), "no such column: nope")
  assert.equal(Db.errorText("Error in 3rd command line argument: database is locked\n", 1), "database is locked")
  assert.equal(Db.errorText("", 5), "sqlite3 exited 5")
})

test("parseCounts: empty output counts zero", () => {
  assert.deepEqual(Db.parseCounts(""), { unreadNotes: 0, pendingTodos: 0, notes: 0, todos: 0, history: 0 })
})

test("parseId: plain integer output", () => {
  assert.equal(Db.parseId("42\n"), 42)
})

test("parseId: empty or non-numeric output", () => {
  assert.equal(Db.parseId(""), -1)
  assert.equal(Db.parseId("abc"), -1)
})

test("q doubles single quotes", () => {
  assert.equal(Db.q("Jane's"), "'Jane''s'")
})

test("likeEscape escapes the backslash first, then the wildcards", () => {
  assert.equal(Db.likeEscape("50%_a\\b"), "50\\%\\_a\\\\b")
})

test("countsSql: the history count is the real total, past the 500 rows historySql reads", (t) => {
  const db = seeded(t)
  db.write("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 600)"
    + " INSERT INTO history (type, title, action, ts) SELECT 'note', 'bulk', 'added', " + T0 + " + i FROM n")
  assert.equal(db.read(Db.historySql()).length, 500)
  const r = db.run(Db.countsSql(), true)
  assert.equal(r.status, 0, r.stderr)
  assert.equal(Db.parseCounts(r.stdout).history, 603)
})
