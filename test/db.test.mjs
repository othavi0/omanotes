import { test } from "node:test"
import assert from "node:assert/strict"
import { spawn as spawnAsync, spawnSync } from "node:child_process"
import { once } from "node:events"
import { setTimeout as sleep } from "node:timers/promises"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { loadQmlLib } from "./lib/load-qml-lib.mjs"

const Db = loadQmlLib(new URL("../data/Db.js", import.meta.url), [
  "q", "likeEscape", "now", "listSql", "countsSql", "addSql", "setStatusSql",
  "updateSql", "deleteItemSql", "convertTypeSql", "historySql", "deleteHistorySql",
  "clearHistorySql", "sqliteCommand", "initCommand", "parseRows", "parseCounts",
  "parseId"
])

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

function spawn(argv) {
  const r = spawnSync(argv[0], argv.slice(1), { encoding: "utf8" })
  if (r.error) throw r.error
  return r
}

// A throwaway database initialised by initCommand and driven through
// sqliteCommand, the same argv Db.qml hands to Process.
function openDb(t) {
  const dir = mkdtempSync(join(tmpdir(), "omanotes-db-"))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  const dataDir = join(dir, "omarchy")
  const path = join(dataDir, "scratchpad.db")
  const init = spawn(Db.initCommand(dataDir, path))
  assert.equal(init.status, 0, init.stderr)
  const db = {
    path,
    run(sql, json) {
      return spawn(Db.sqliteCommand(path, sql, json))
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

function ids(rows) {
  return rows.map((r) => r.id)
}

test("initCommand creates the data dir and both tables, and is safe to rerun", (t) => {
  const db = openDb(t)
  assert.equal(spawn(Db.initCommand(join(db.path, ".."), db.path)).status, 0)
  const tables = db.read("SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('items', 'history') ORDER BY name")
  assert.deepEqual(tables.map((r) => r.name), ["history", "items"])
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

test("initCommand: start-up on a new database waits for a lock held by another process", { timeout: 10000 }, async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "omanotes-db-"))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  const path = join(dir, "scratchpad.db")
  const { status, stderr } = await runWhileLocked(t, path, Db.initCommand(dir, path))
  assert.equal(status, 0, stderr)
  const tables = spawn(["sqlite3", path, "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('items', 'history') ORDER BY name"])
  assert.equal(tables.stdout, "history\nitems\n")
})

test("sqliteCommand: a write waits for a lock held by another process", { timeout: 10000 }, async (t) => {
  const db = seed(openDb(t))
  const { status, stderr } = await runWhileLocked(t, db.path, Db.sqliteCommand(db.path, Db.deleteHistorySql(1), false))
  assert.equal(status, 0, stderr)
  assert.deepEqual(ids(db.history()), [2, 3])
})

test("listSql: all items, status 0 (unread or pending) first, then most recent", (t) => {
  const db = seed(openDb(t))
  assert.deepEqual(ids(db.read(Db.listSql("all", ""))), [2, 1, 3, 5, 4])
})

test("listSql: type filter", (t) => {
  const db = seed(openDb(t))
  assert.deepEqual(ids(db.read(Db.listSql("todo", ""))), [2, 3, 5])
  assert.deepEqual(ids(db.read(Db.listSql("note", ""))), [1, 4])
})

test("listSql: an invalid filter lists every item", (t) => {
  const db = seed(openDb(t))
  assert.deepEqual(ids(db.read(Db.listSql("bogus", ""))), [2, 1, 3, 5, 4])
  assert.deepEqual(ids(db.read(Db.listSql("note' OR 1=1 --", ""))), [2, 1, 3, 5, 4])
})

test("listSql: search matches title or body and ignores ASCII case", (t) => {
  const db = seed(openDb(t))
  assert.deepEqual(ids(db.read(Db.listSql("all", "DOMAIN"))), [2])
  assert.deepEqual(ids(db.read(Db.listSql("all", "grind"))), [4])
  assert.deepEqual(ids(db.read(Db.listSql("note", "domain"))), [])
  assert.deepEqual(ids(db.read(Db.listSql("all", "   "))), [2, 1, 3, 5, 4])
})

test("listSql: a quote and LIKE wildcards in the search are matched literally", (t) => {
  const db = openDb(t)
  db.write("INSERT INTO items (id, type, title, status, created_at, updated_at) VALUES"
    + " (1, 'note', 'it''s 100% done', 0, 1, 1),"
    + " (2, 'note', 'it''s 1000 done', 0, 2, 2),"
    + " (3, 'note', 'a\\b', 0, 3, 3)")
  assert.deepEqual(ids(db.read(Db.listSql("all", "it's 100%"))), [1])
  assert.deepEqual(ids(db.read(Db.listSql("all", "_"))), [])
  assert.deepEqual(ids(db.read(Db.listSql("all", "a\\b"))), [3])
})

test("countsSql: empty database counts zero", (t) => {
  const db = openDb(t)
  assert.deepEqual(db.read(Db.countsSql()), [{ unreadNotes: 0, inProgressTodos: 0, notes: 0, todos: 0 }])
})

test("countsSql: unread notes, pending todos and totals per type", (t) => {
  const db = seed(openDb(t))
  assert.deepEqual(db.read(Db.countsSql()), [{ unreadNotes: 1, inProgressTodos: 2, notes: 2, todos: 3 }])
})

test("addSql: stores the item, prints its id and logs it as added", (t) => {
  const db = seed(openDb(t))
  const id = Db.parseId(db.write(atT0(() => Db.addSql("todo", "Jane's list", "milk, 'eggs'"))))
  assert.equal(id, 6)
  assert.deepEqual(db.item(id), {
    id: 6, type: "todo", title: "Jane's list", body: "milk, 'eggs'", status: 0, created_at: T0, updated_at: T0
  })
  assert.deepEqual(db.history().at(-1), { id: 4, type: "todo", title: "Jane's list", action: "added", ts: T0 })
})

test("addSql: an empty body is stored as NULL and an unknown type as a note", (t) => {
  const db = openDb(t)
  const id = Db.parseId(db.write(atT0(() => Db.addSql("bogus", "Buy milk", ""))))
  assert.equal(db.item(id).body, null)
  assert.equal(db.item(id).type, "note")
})

test("setStatusSql: completing a todo", (t) => {
  const db = seed(openDb(t))
  db.write(atT0(() => Db.setStatusSql(2, 1)))
  assert.equal(db.item(2).status, 1)
  assert.equal(db.item(2).updated_at, T0)
  assert.deepEqual(db.history().at(-1), { id: 4, type: "todo", title: "Renew the domain", action: "completed", ts: T0 })
})

test("setStatusSql: marking a read note unread logs it as reopened", (t) => {
  const db = seed(openDb(t))
  db.write(atT0(() => Db.setStatusSql(4, 0)))
  assert.equal(db.item(4).status, 0)
  assert.deepEqual(db.history().at(-1), { id: 4, type: "note", title: "Buy coffee", action: "reopened", ts: T0 })
})

test("setStatusSql: a missing id records nothing", (t) => {
  const db = seed(openDb(t))
  const before = db.snapshot()
  db.write(atT0(() => Db.setStatusSql(99, 1)))
  assert.deepEqual(db.snapshot(), before)
})

test("updateSql: new title and body, logged with the new title", (t) => {
  const db = seed(openDb(t))
  db.write(atT0(() => Db.updateSql(3, "Answer the review", "by Friday")))
  const row = db.item(3)
  assert.deepEqual([row.title, row.body, row.updated_at, row.created_at], ["Answer the review", "by Friday", T0, T0 - 10800])
  assert.deepEqual(db.history().at(-1), { id: 4, type: "todo", title: "Answer the review", action: "edited", ts: T0 })
})

test("updateSql: an emptied body is stored as NULL", (t) => {
  const db = seed(openDb(t))
  db.write(atT0(() => Db.updateSql(1, "Ideas for the panel", "")))
  assert.equal(db.item(1).body, null)
})

test("deleteItemSql: removes the item and logs its title", (t) => {
  const db = seed(openDb(t))
  db.write(atT0(() => Db.deleteItemSql(4)))
  assert.equal(db.item(4), undefined)
  assert.deepEqual(ids(db.read(Db.listSql("all", ""))), [2, 1, 3, 5])
  assert.deepEqual(db.history().at(-1), { id: 4, type: "note", title: "Buy coffee", action: "deleted", ts: T0 })
})

test("convertTypeSql: flips the type, keeps the status and logs the new type", (t) => {
  const db = seed(openDb(t))
  db.write(atT0(() => Db.convertTypeSql(4)))
  assert.deepEqual([db.item(4).type, db.item(4).status, db.item(4).updated_at], ["todo", 1, T0])
  assert.deepEqual(db.history().at(-1), { id: 4, type: "todo", title: "Buy coffee", action: "converted", ts: T0 })
  db.write(atT0(() => Db.convertTypeSql(4)))
  assert.equal(db.item(4).type, "note")
})

test("a non-numeric id changes no row", (t) => {
  const db = seed(openDb(t))
  const before = db.snapshot()
  for (const sql of atT0(() => [
    Db.setStatusSql("abc", 1),
    Db.updateSql("abc", "x", "y"),
    Db.deleteItemSql("abc"),
    Db.convertTypeSql("abc"),
    Db.deleteHistorySql("abc")
  ])) {
    db.run(sql, false)
    assert.deepEqual(db.snapshot(), before, sql)
  }
})

for (const [name, build, failOn] of [
  ["addSql", () => Db.addSql("todo", "Renew the car", ""), "INSERT ON history"],
  ["setStatusSql", () => Db.setStatusSql(2, 1), "INSERT ON history"],
  ["updateSql", () => Db.updateSql(2, "Renew the car", "x"), "INSERT ON history"],
  ["convertTypeSql", () => Db.convertTypeSql(2), "INSERT ON history"],
  ["deleteItemSql", () => Db.deleteItemSql(2), "DELETE ON items"]
]) {
  test(name + ": a failing second change writes nothing", (t) => {
    const db = seed(openDb(t))
    db.write("CREATE TRIGGER fail_second BEFORE " + failOn + " BEGIN SELECT RAISE(ABORT, 'forced'); END")
    const before = db.snapshot()
    const r = db.run(atT0(build), false)
    assert.notEqual(r.status, 0)
    assert.match(r.stderr, /forced/)
    assert.deepEqual(db.snapshot(), before)
  })
}

test("historySql: newest first, capped at 500 rows", (t) => {
  const db = seed(openDb(t))
  assert.deepEqual(ids(db.read(Db.historySql())), [1, 2, 3])
  db.write("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 600)"
    + " INSERT INTO history (type, title, action, ts) SELECT 'note', 'bulk', 'added', " + T0 + " + i FROM n")
  const rows = db.read(Db.historySql())
  assert.equal(rows.length, 500)
  assert.equal(rows[0].ts, T0 + 600)
  assert.equal(rows[499].ts, T0 + 101)
})

test("deleteHistorySql removes one row, clearHistorySql all of them, items stay", (t) => {
  const db = seed(openDb(t))
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

test("parseRows: garbage falls back to []", () => {
  assert.deepEqual(Db.parseRows("not json"), [])
})

test("parseCounts: empty output counts zero", () => {
  assert.deepEqual(Db.parseCounts(""), { unreadNotes: 0, inProgressTodos: 0, notes: 0, todos: 0 })
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
