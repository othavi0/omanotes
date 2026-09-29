// Runs the SQL of before the binary (test/lib/legacy-db.js) once, the way the
// parity tests ran it, and writes what it left into test/fixtures/parity/.
// Run: node test/lib/freeze-parity.mjs
import assert from "node:assert/strict"
import { mkdirSync, writeFileSync } from "node:fs"
import { Legacy, T0, TABLES, atT0, cli, legacyDb, legacyNewDb, pair, rows, run, tempDb } from "./bin-fixture.mjs"

const OUT = new URL("../fixtures/parity/", import.meta.url).pathname
// The clock of the prune steps. The old prune read SQLite's clock; the binary
// takes the caller's `at`, so the frozen run and the test share this one.
export const NOW = T0 + 100 * 86400

const cleanups = []
const t = { after: (fn) => cleanups.push(fn) }

function tables(path) {
  const out = {}
  for (const [name, sql] of Object.entries(TABLES)) out[name] = rows(path, sql)
  return out
}

// The old prune with SQLite's clock replaced by NOW.
function atNow(sql) {
  const fix = (s) => s.replaceAll("CAST(strftime('%s', 'now') AS INTEGER)", String(NOW))
  const list = Array.isArray(sql) ? sql : [sql]
  assert.ok(list.some((s) => s.includes("strftime('%s', 'now')")), "the step prunes")
  return list.map(fix)
}

function settingsPatch(patch) {
  return () => Legacy.setSettingsSql(patch)
}

// One step: the old SQL on `path`, then every table and what it printed.
function step(path, label, sql, { now = false } = {}) {
  const built = atT0(sql)
  const out = cli(path, now ? atNow(built) : built)
  return { label, out, tables: tables(path) }
}

function itemWrites() {
  const p = pair(t)
  const start = tables(p.old)
  const steps = [
    ["add a note with a body", () => Legacy.addSql("note", "Ação O'Brien", "line1\nline2")],
    ["add a todo without a body", () => Legacy.addSql("todo", "Plain", "")],
    ["add with quotes, a backslash and wildcards", () => Legacy.addSql("note", "It's \"x\" \\ %_", "b'")],
    ["add with a body left out", () => Legacy.addSql("note", "No body", undefined)],
    ["complete a todo", () => Legacy.setStatusSql(2, 1)],
    ["complete it again", () => Legacy.setStatusSql(2, 1)],
    ["reopen a read note", () => Legacy.setStatusSql(4, 0)],
    ["edit", () => Legacy.updateSql(1, "Ideas v2", "new body")],
    ["edit only the case (the trigger folds again)", () => Legacy.updateSql(1, "IDEAS V2", "new body")],
    ["edit to an empty body", () => Legacy.updateSql(3, "Reply", "")],
    ["convert", () => Legacy.convertTypeSql(3)],
    ["move after, in the second block", () => Legacy.moveSql(5, 2, true)],
    ["move before, in the first block", () => Legacy.moveSql(3, 1, false)],
    ["move across blocks", () => Legacy.moveSql(1, 2, true)],
    ["move onto itself", () => Legacy.moveSql(1, 1, true)],
    ["delete", () => Legacy.deleteItemSql(5)],
    ["complete a missing id", () => Legacy.setStatusSql(999, 1)],
    ["edit a missing id", () => Legacy.updateSql(999, "x", "")],
    ["convert a missing id", () => Legacy.convertTypeSql(999)],
    ["delete a missing id", () => Legacy.deleteItemSql(999)],
    ["move to a missing anchor", () => Legacy.moveSql(1, 999, true)]
  ].map(([label, sql]) => {
    const s = step(p.old, label, sql)
    const result = label.startsWith("add") ? { id: Legacy.parseId(s.out) } : { found: Legacy.parseFound(s.out) }
    return { label, result, tables: s.tables }
  })
  return { start, steps }
}

function historyAndSettings() {
  const p = pair(t)
  const steps = [
    ["delete one history entry", () => Legacy.deleteHistorySql(2)],
    ["delete a missing history entry", () => Legacy.deleteHistorySql(999)],
    ["prune 30 days", () => Legacy.pruneHistorySql(30), true],
    ["one setting", settingsPatch({ volume: 55 })],
    ["several settings, a quote in the text", settingsPatch({ soundOn: false, sound: "x'y", soundFile: "/tmp/a b.oga", snoozeMinutes: 12 })],
    ["Keep 90 days", settingsPatch({ historyDays: 90 }), true],
    ["clear history", () => Legacy.clearHistorySql()]
  ].map(([label, sql, now]) => {
    const s = step(p.old, label, sql, { now })
    return { label, tables: s.tables }
  })
  return { steps }
}

function shorterKeep() {
  const p = pair(t)
  cli(p.old, `INSERT INTO history (type, title, action, ts) VALUES ('note', 'recent', 'added', ${NOW - 86400}), ('note', 'old', 'added', ${NOW - 40 * 86400})`)
  return { tables: step(p.old, "Keep 30 days", settingsPatch({ historyDays: 30 }), { now: true }).tables }
}

function settingsStart() {
  return { tables: tables(pair(t).old) }
}

const ALARM = { hour: 7, minute: 30, label: "Wake", days: [1, 2, 3], enabled: true, snoozeMinutes: 9, ringMinutes: 5, snoozedUntil: 0, lastFiredAt: 0, armedAt: 1700000000000, autoSnoozes: 0 }

function alarmWrites() {
  const p = pair(t)
  const ins = step(p.old, "insert", () => Legacy.insertAlarmSql(ALARM))
  const id = Legacy.parseId(ins.out)
  const saved = { ...ALARM, id, hour: 8, days: [0, 6, 6, 9, 2.5], label: "Café", enabled: false, snoozedUntil: 1700000600000 }
  const steps = [
    { label: "insert", result: { id }, tables: ins.tables },
    ...[
      ["save", () => Legacy.saveAlarmSql(saved)],
      ["save a missing alarm", () => Legacy.saveAlarmSql({ ...saved, id: 999 })],
      ["insert a second", () => Legacy.insertAlarmSql({ ...ALARM, minute: 45 })],
      ["delete", () => Legacy.deleteAlarmSql(saved.id)],
      ["delete a missing alarm", () => Legacy.deleteAlarmSql(999)]
    ].map(([label, sql]) => {
      const s = step(p.old, label, sql)
      const result = label.startsWith("insert") ? { id: Legacy.parseId(s.out) } : { found: Legacy.parseFound(s.out) }
      return { label, result, tables: s.tables }
    })
  ]
  return { steps }
}

function search() {
  const p = pair(t)
  cli(p.old, "INSERT INTO items (type, title, body, status, created_at, updated_at, position) VALUES ('note', 'Café com Leite', 'AÇÃO urgente', 0, 1, 1, 1), ('todo', 'ÑANDÚ 100%', 'a_b', 0, 1, 1, 2), ('note', 'Straße Ωmega', NULL, 1, 1, 1, 1), ('todo', 'back\\slash', 'x', 0, 1, 1, 3)")
  const views = []
  for (const query of ["cafe", "CAFÉ", "acao", "100%", "a_b", "nandu", "straße", "ω", "\\", "_", "%", "zzz", "e"]) {
    for (const filter of ["all", "note", "todo", "bogus"]) {
      views.push({ filter, query, ids: rows(p.old, Legacy.listSql(filter, query)).map((r) => r.id) })
    }
  }
  const empty = {
    all: rows(p.old, Legacy.listSql("all", "")).map((r) => r.id),
    todo: rows(p.old, Legacy.listSql("todo", "")).map((r) => r.id)
  }
  return { views, empty }
}

function master(path) {
  return rows(path, "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name")
}

function schema() {
  const fresh = legacyNewDb(t)
  const v0 = legacyDb(t)
  const migrated = {}
  for (const table of ["items", "history", "alarms", "settings", "sqlite_sequence"]) {
    migrated[table] = rows(v0, `SELECT * FROM ${table} ORDER BY 1`)
  }
  return {
    version: Legacy.MIGRATIONS.length,
    firstMigration: Legacy.MIGRATIONS[0],
    newFile: { master: master(fresh), settings: rows(fresh, "SELECT * FROM settings"), userVersion: rows(fresh, "PRAGMA user_version")[0].user_version },
    v0WithRows: { master: master(v0), tables: migrated, userVersion: rows(v0, "PRAGMA user_version")[0].user_version }
  }
}

// bin-cells.test.mjs: the file each case builds, read with the old SELECTs
// through the CLI, kept as the CLI's text, and what the old parsers made of it.
const HOSTILE = {
  "text number": "'7'",
  "text with spaces": "' 7 '",
  "hex text": "'0x10'",
  "comma text": "'1,5'",
  "empty text": "''",
  "real": "6.6",
  "real that is whole": "7.0",
  "real half": "2.5",
  "negative real half": "-2.5",
  "tiny real": "1e-300",
  "negative zero": "-0.0",
  "huge integer": "9007199254740993",
  "negative": "-4",
  "blob": "x'00ff41e9'",
  "invalid UTF-8": "CAST(x'61ff62' AS TEXT)",
  "emoji": "'😀'",
  "control characters": "char(1) || char(10) || '\"\\'",
  "infinity": "9e999",
  "minus infinity": "-9e999"
}
const SETTINGS_COLUMNS = ["sound_on", "sound", "sound_file", "volume", "snooze_minutes", "ring_minutes", "history_days", "check_updates"]
const ALARM_COLUMNS = ["hour", "minute", "label", "days", "enabled", "snooze_minutes", "ring_minutes", "snoozed_until_ms", "last_fired_at_ms", "armed_at_ms", "auto_snoozes"]

function oldParse(parse, text) {
  try {
    return { value: parse(text) }
  } catch (e) {
    return { threw: e.message }
  }
}

// The file bin-cells builds, through the binary as it builds it.
function hostileDb() {
  const path = tempDb(t)
  run(path, "alarm.insert", { alarm: { hour: 7, minute: 30, label: "Wake", days: 62, enabled: 1, snooze_minutes: 9, ring_minutes: 5, snoozed_until_ms: 0, last_fired_at_ms: 0, armed_at_ms: 1, auto_snoozes: 0 } }, { by: "service" })
  run(path, "item.add", { type: "note", title: "n", body: "b" })
  return path
}

// The bytes of the file hang on SQLite's page layout, not on the old read.
const noBytes = (text) => text.replace(/,"db_bytes":\d+/g, "")

function reads(path) {
  const text = {
    settings: noBytes(cli(path, Legacy.settingsSql(), { json: true })),
    alarms: cli(path, Legacy.alarmsSql(), { json: true }),
    counts: cli(path, Legacy.countsSql(), { json: true }),
    items: cli(path, Legacy.listSql("all", ""), { json: true }),
    history: cli(path, Legacy.historySql(), { json: true })
  }
  const parsed = {
    settings: oldParse(Legacy.parseSettings, text.settings),
    alarms: oldParse(Legacy.parseAlarms, text.alarms),
    counts: oldParse(Legacy.parseCounts, text.counts)
  }
  if (parsed.settings.value) delete parsed.settings.value.bytes
  return { text, parsed }
}

function cells() {
  const cases = {}
  for (const [name, cell] of Object.entries(HOSTILE)) {
    const path = hostileDb()
    cli(path, ["PRAGMA ignore_check_constraints = ON",
      `UPDATE settings SET ${SETTINGS_COLUMNS.map((c) => `${c} = ${cell}`).join(", ")}`,
      `UPDATE alarms SET ${ALARM_COLUMNS.map((c) => `${c} = ${cell}`).join(", ")}`,
      `UPDATE items SET status = ${cell}, created_at = ${cell}, updated_at = ${cell}, title = ${cell}`,
      `UPDATE history SET ts = ${cell}, action = ${cell}`])
    cases[name] = reads(path)
  }
  const deleted = hostileDb()
  cli(deleted, "DELETE FROM settings")
  const nul = hostileDb()
  cli(nul, "UPDATE items SET title = 'a' || char(0) || 'b', body = NULL")
  return {
    cases,
    deletedSettings: noBytes(cli(deleted, Legacy.settingsSql(), { json: true })),
    nulTitle: rows(nul, Legacy.listSql("all", ""))[0].title
  }
}

// JSON.stringify writes Infinity as null and -0 as 0; nothing frozen may hold either.
function check(value, where) {
  if (typeof value === "number") assert.ok(Number.isFinite(value) && !Object.is(value, -0), `${where}: ${value}`)
  else if (value && typeof value === "object") for (const [k, v] of Object.entries(value)) check(v, `${where}.${k}`)
}

// One row per line, so a diff of a fixture reads row by row.
function pretty(value, indent = "") {
  const inner = indent + "  "
  if (Array.isArray(value)) {
    if (value.length === 0 || value.every((v) => v === null || typeof v !== "object" || !Object.values(v).some((x) => x && typeof x === "object"))) {
      if (value.every((v) => v === null || typeof v !== "object")) return JSON.stringify(value)
      return "[\n" + value.map((v) => inner + JSON.stringify(v)).join(",\n") + "\n" + indent + "]"
    }
    return "[\n" + value.map((v) => inner + pretty(v, inner)).join(",\n") + "\n" + indent + "]"
  }
  if (value && typeof value === "object") {
    const keys = Object.keys(value)
    if (keys.length === 0) return "{}"
    return "{\n" + keys.map((k) => inner + JSON.stringify(k) + ": " + pretty(value[k], inner)).join(",\n") + "\n" + indent + "}"
  }
  return JSON.stringify(value)
}

function write(name, value) {
  check(value, name)
  const text = pretty(value) + "\n"
  assert.deepEqual(JSON.parse(text), value, `${name} reads back the same`)
  writeFileSync(OUT + name, text)
}

try {
  mkdirSync(OUT, { recursive: true })
  write("writes.json", {
    now: NOW,
    items: itemWrites(),
    historyAndSettings: historyAndSettings(),
    shorterKeep: shorterKeep(),
    settingsStart: settingsStart(),
    alarms: alarmWrites(),
    search: search()
  })
  write("schema.json", schema())
  write("cells.json", cells())
} finally {
  for (const fn of cleanups) fn()
}
