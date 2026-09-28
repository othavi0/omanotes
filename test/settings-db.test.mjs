import { test } from "node:test"
import assert from "node:assert/strict"
import { setTimeout as sleep } from "node:timers/promises"
import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { loadQmlLib } from "./lib/load-qml-lib.mjs"
import { Db, DB_JS, NAMES, T0, spawn, start, openDb, openV0Db, dbAt, seed, seeded } from "./lib/db-fixture.mjs"

const Alarm = loadQmlLib(new URL("../data/Alarm.js", import.meta.url),
  ["MIN_SNOOZE_MINUTES", "MAX_SNOOZE_MINUTES", "DEFAULT_SNOOZE_MINUTES", "MIN_RING_MINUTES", "MAX_RING_MINUTES", "DEFAULT_RING_MINUTES"])
const Settings = loadQmlLib(new URL("../ui/Settings.js", import.meta.url), ["KEEP_CHOICES"])

const SETTING_DEFAULTS = {
  soundOn: true, sound: "alarm-clock-elapsed", soundFile: "", volume: 100, snoozeMinutes: 9, ringMinutes: 5,
  historyDays: 0, checkUpdates: true
}

function settingsOf(db) {
  const r = db.run(Db.settingsSql(), true)
  assert.equal(r.status, 0, r.stderr)
  return Db.parseSettings(r.stdout)
}

test("start-up creates one settings row with the defaults, and a version 4 database with rows gains it and keeps every row", (t) => {
  const db = openDb(t)
  assert.deepEqual(db.read("SELECT COUNT(*) AS n FROM settings")[0].n, 1)
  const read = settingsOf(db)
  assert.deepEqual(read.settings, SETTING_DEFAULTS)
  assert.equal(read.bytes, db.bytes().length, "the size is the file's")
  const V4 = loadQmlLib(DB_JS, NAMES)
  V4.MIGRATIONS.splice(4)
  const old = seed(openV0Db(t))
  start(old.path, undefined, V4)
  assert.equal(old.version(), 4)
  const before = old.snapshot()
  start(old.path)
  assert.equal(old.version(), Db.MIGRATIONS.length)
  assert.deepEqual(old.snapshot(), before)
  assert.deepEqual(settingsOf(old).settings, SETTING_DEFAULTS)
})

test("the settings table refuses a second row and values out of range written with sqlite3", (t) => {
  const db = openDb(t)
  for (const sql of ["INSERT INTO settings (id) VALUES (2)", "UPDATE settings SET volume = 101", "UPDATE settings SET volume = -1",
    "UPDATE settings SET snooze_minutes = 0", "UPDATE settings SET ring_minutes = 61", "UPDATE settings SET sound_on = 2",
    "UPDATE settings SET history_days = -1", "UPDATE settings SET history_days = 7", "UPDATE settings SET check_updates = 2"]) {
    const r = db.run(sql, false)
    assert.notEqual(r.status, 0, sql)
    assert.match(r.stderr, /CHECK constraint failed/, sql)
  }
  assert.deepEqual(settingsOf(db).settings, SETTING_DEFAULTS)
})

test("setSettingsSql writes only the keys it is given, and sending it twice leaves the same row", (t) => {
  const db = openDb(t)
  const sql = Db.setSettingsSql({ volume: 40, soundOn: false, sound: "custom", soundFile: "/home/me/it's here.ogg" })
  db.write(sql)
  db.write(sql)
  db.write(Db.setSettingsSql({ snoozeMinutes: 12 }))
  assert.deepEqual(settingsOf(db).settings,
    { ...SETTING_DEFAULTS, volume: 40, soundOn: false, sound: "custom", soundFile: "/home/me/it's here.ogg", snoozeMinutes: 12 })
  assert.equal(db.read("SELECT COUNT(*) AS n FROM settings")[0].n, 1)
})

test("setSettingsSql brings a row deleted by hand back, and the read shows the defaults until then", (t) => {
  const db = openDb(t)
  db.write("DELETE FROM settings")
  assert.deepEqual(settingsOf(db).settings, SETTING_DEFAULTS, "no row reads as the defaults")
  assert.ok(settingsOf(db).bytes > 0, "and still carries the size")
  db.write(Db.setSettingsSql({ ringMinutes: 7 }))
  assert.deepEqual(settingsOf(db).settings, { ...SETTING_DEFAULTS, ringMinutes: 7 })
})

test("the settings row takes the Keep choices, the same ones the page offers", (t) => {
  const db = openDb(t)
  for (const days of Db.SETTINGS.historyDays.options) db.write("UPDATE settings SET history_days = " + days)
  assert.deepEqual([...Db.SETTINGS.historyDays.options].sort((a, b) => a - b), Settings.KEEP_CHOICES.map((c) => c.value).sort((a, b) => a - b))
})

test("the new-alarm defaults take the ranges and the defaults of the alarm maths", () => {
  assert.deepEqual([Db.SETTINGS.snoozeMinutes.min, Db.SETTINGS.snoozeMinutes.max, Db.SETTINGS.snoozeMinutes.fallback],
    [Alarm.MIN_SNOOZE_MINUTES, Alarm.MAX_SNOOZE_MINUTES, Alarm.DEFAULT_SNOOZE_MINUTES])
  assert.deepEqual([Db.SETTINGS.ringMinutes.min, Db.SETTINGS.ringMinutes.max, Db.SETTINGS.ringMinutes.fallback],
    [Alarm.MIN_RING_MINUTES, Alarm.MAX_RING_MINUTES, Alarm.DEFAULT_RING_MINUTES])
})

test("no file in ui/ imports Db.js: a page reaches the database through its Db", () => {
  const ui = new URL("../ui/", import.meta.url)
  const importers = readdirSync(ui).filter((f) => f.endsWith(".qml") && readFileSync(new URL(f, ui), "utf8").includes('"../data/Db.js"'))
  assert.deepEqual(importers, [])
})

test("setSettingsSql names an unknown key", () => {
  assert.throws(() => Db.setSettingsSql({ volume: 50, colour: "red" }), /^Error: unknown setting: colour$/)
})

test("setSettingsSql refuses an unknown key, a value outside its spec and an empty patch before any SQL exists", () => {
  for (const patch of [{ colour: "red" }, { volume: -1 }, { volume: 101 }, { volume: 50.5 }, { volume: "50" },
    { snoozeMinutes: 0 }, { ringMinutes: 61 }, { historyDays: 7 }, { soundOn: 1 }, { checkUpdates: "yes" },
    { sound: 3 }, { soundFile: null }, {}]) {
    assert.throws(() => Db.setSettingsSql(patch), /setting/, JSON.stringify(patch))
  }
})

test("parseSettings turns a row a hand edit left out of range into settings the builders accept", () => {
  const text = JSON.stringify([{ id: 1, sound_on: 0, sound: "bell", sound_file: "", volume: 250, snooze_minutes: 0,
    ring_minutes: 6.4, history_days: 7, check_updates: 5, db_bytes: 12288 }])
  assert.deepEqual(Db.parseSettings(text), {
    settings: { ...SETTING_DEFAULTS, soundOn: false, sound: "bell", volume: 100, snoozeMinutes: 1, ringMinutes: 6 },
    bytes: 12288
  })
  assert.deepEqual(Db.parseSettings(""), { settings: SETTING_DEFAULTS, bytes: 0 }, "a Db not read yet has the defaults")
  assert.throws(() => Db.parseSettings("not json"), /unreadable/)
})

test("mergeSettings lays a patch over the settings without changing them in place", () => {
  const base = Db.parseSettings("").settings
  const merged = Db.mergeSettings(base, { volume: 30, soundOn: false })
  assert.deepEqual(merged, { ...SETTING_DEFAULTS, volume: 30, soundOn: false })
  assert.deepEqual(base, SETTING_DEFAULTS)
})

const DAY = 86400

// History entries aged `days` from now, as the prune measures them.
function agedHistory(db, days) {
  const now = Math.floor(Date.now() / 1000)
  db.write("INSERT INTO history (type, title, action, ts) VALUES "
    + days.map((d) => "('note', 'aged " + d + "', 'added', " + (now - d * DAY) + ")").join(", "))
}
function historyTitles(db) {
  return db.read("SELECT title FROM history ORDER BY ts DESC").map((r) => r.title)
}

test("keeping 30 days removes, in the same write, only the entries older than 30 days", (t) => {
  const db = openDb(t)
  agedHistory(db, [1, 29, 31, 95])
  const sql = Db.setSettingsSql({ historyDays: 30 })
  assert.equal(sql[0], "BEGIN IMMEDIATE")
  assert.equal(sql[sql.length - 1], "COMMIT")
  db.write(sql)
  assert.deepEqual(historyTitles(db), ["aged 1", "aged 29"])
  assert.equal(settingsOf(db).settings.historyDays, 30)
})

test("keeping entries forever removes none", (t) => {
  const db = openDb(t)
  agedHistory(db, [1, 400])
  db.write(Db.setSettingsSql({ historyDays: 0 }))
  assert.deepEqual(historyTitles(db), ["aged 1", "aged 400"])
})

test("a prune with nothing past the cutoff leaves the file untouched, so no watcher fires", async (t) => {
  const db = openDb(t)
  agedHistory(db, [1, 10])
  const before = db.bytes()
  const mtime = statSync(db.path).mtimeMs
  await sleep(20)
  db.write(Db.pruneHistorySql(30))
  assert.deepEqual(db.bytes(), before)
  assert.equal(statSync(db.path).mtimeMs, mtime)
  assert.throws(() => Db.pruneHistorySql(0), /invalid value/)
})

test("the counts carry the oldest history entry, for the prune on open", (t) => {
  const db = openDb(t)
  const now = Math.floor(Date.now() / 1000)
  agedHistory(db, [3, 40])
  const counts = Db.parseCounts(db.run(Db.countsSql(), true).stdout)
  assert.equal(counts.oldestHistory, now - 40 * DAY)
})

test("prunes: only a Keep of some days with an entry older than them removes anything", () => {
  const now = T0
  assert.equal(Db.prunes(30, now - 31 * DAY, now), true)
  assert.equal(Db.prunes(30, now - 29 * DAY, now), false)
  assert.equal(Db.prunes(0, now - 400 * DAY, now), false, "forever keeps everything")
  assert.equal(Db.prunes(30, 0, now), false, "an empty history has nothing to remove")
})

test("backupCommand copies the database next to it under today's date, and a second copy that day replaces the first", (t) => {
  const db = seeded(t)
  const dir = dirname(db.path)
  const copy = join(dir, "scratchpad-2026-09-28.db")
  assert.equal(Db.backupName("2026-09-28"), "scratchpad-2026-09-28.db")
  let r = spawn(Db.backupCommand(db.path, dir, "2026-09-28"))
  assert.equal(r.status, 0, r.stderr)
  assert.deepEqual(dbAt(copy).snapshot(), db.snapshot())
  db.write(Db.addSql("note", "after the first copy", ""))
  r = spawn(Db.backupCommand(db.path, dir, "2026-09-28"))
  assert.equal(r.status, 0, r.stderr)
  assert.deepEqual(dbAt(copy).snapshot(), db.snapshot())
  assert.deepEqual(readdirSync(dir).sort(), ["scratchpad-2026-09-28.db", "scratchpad.db"], "no temporary file is left")
})

test("a backup that fails leaves the earlier copy of the day as it was", (t) => {
  const db = seeded(t)
  const dir = dirname(db.path)
  const copy = join(dir, "scratchpad-2026-09-28.db")
  assert.equal(spawn(Db.backupCommand(db.path, dir, "2026-09-28")).status, 0)
  const before = readFileSync(copy)
  const broken = join(dir, "broken.db")
  writeFileSync(broken, "not a database, but long enough to be read as one ".repeat(20))
  const r = spawn(Db.backupCommand(broken, dir, "2026-09-28"))
  assert.notEqual(r.status, 0)
  assert.match(r.stderr, /not a database/)
  assert.deepEqual(readFileSync(copy), before)
})
