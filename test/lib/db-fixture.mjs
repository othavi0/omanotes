// The database fixture the db tests share: Db.js loaded under Node, and
// throwaway databases started the way DbCore starts them.
import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { loadQmlLib } from "./load-qml-lib.mjs"

export const DB_JS = new URL("../../data/Db.js", import.meta.url)
export const NAMES = [
  "q", "likeEscape", "now", "listSql", "countsSql", "addSql", "setStatusSql",
  "updateSql", "deleteItemSql", "convertTypeSql", "historySql", "deleteHistorySql",
  "clearHistorySql", "sqliteCommand", "initCommand", "MIGRATIONS", "migrateSql",
  "parseVersion", "migrationRaced", "parseRows", "parseCounts", "parseId", "parseFound",
  "errorText", "moveSql", "movedRows", "sqlInt", "daysMask", "maskDays", "alarmsSql", "insertAlarmSql",
  "saveAlarmSql", "deleteAlarmSql", "parseAlarms", "mergeAlarms", "SETTINGS", "settingsSql", "setSettingsSql",
  "parseSettings", "mergeSettings", "pruneHistorySql", "prunes", "backupName", "backupCommand"
]
export const Db = loadQmlLib(DB_JS, NAMES)

// The schema every database had before it was versioned, as the live one
// still has it at user_version 0.
export const V0_SCHEMA = "CREATE TABLE IF NOT EXISTS items ("
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

export const T0 = 1700000000

export function atT0(fn) {
  const real = Date.now
  Date.now = () => T0 * 1000
  try {
    return fn()
  } finally {
    Date.now = real
  }
}

export function spawn(argv, env) {
  const r = spawnSync(argv[0], argv.slice(1), { encoding: "utf8", env })
  if (r.error) throw r.error
  return r
}

export function start(path, env, lib = Db) {
  const read = spawn(lib.initCommand(dirname(path), path), env)
  assert.equal(read.status, 0, read.stderr)
  const sql = lib.migrateSql(lib.parseVersion(read.stdout))
  if (sql.length === 0) return
  const migrate = spawn(lib.sqliteCommand(path, sql, false), env)
  assert.equal(migrate.status, 0, migrate.stderr)
}

export function tempPath(t) {
  const dir = mkdtempSync(join(tmpdir(), "omanotes-db-"))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  return join(dir, "omarchy", "scratchpad.db")
}

export function openDb(t, env) {
  const path = tempPath(t)
  start(path, env)
  return dbAt(path, env)
}

// A database as the live one is before versioning: the old schema, at version 0.
export function openV0Db(t, env) {
  const path = tempPath(t)
  mkdirSync(dirname(path))
  assert.equal(spawn(["sqlite3", path, V0_SCHEMA]).status, 0)
  return dbAt(path, env)
}

export function dbAt(path, env) {
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

export function seed(db) {
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
export function seeded(t, env) {
  const db = seed(openV0Db(t, env))
  start(db.path, env)
  return db
}
