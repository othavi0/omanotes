// The settings row (ADR-0016): SETTINGS in data/Db.js checks and coerces it,
// the binary writes the columns it is sent and the schema's CHECKs refuse the
// rest.
import { test } from "node:test"
import assert from "node:assert/strict"
import { setTimeout as sleep } from "node:timers/promises"
import { readdirSync, readFileSync, statSync } from "node:fs"
import { loadQmlLib } from "./lib/load-qml-lib.mjs"
import { Db, T0, cli, newDb, rows, run, sync, v0Db } from "./lib/bin-fixture.mjs"

const Alarm = loadQmlLib(new URL("../data/Alarm.js", import.meta.url),
  ["MIN_SNOOZE_MINUTES", "MAX_SNOOZE_MINUTES", "DEFAULT_SNOOZE_MINUTES", "MIN_RING_MINUTES", "MAX_RING_MINUTES", "DEFAULT_RING_MINUTES"])
const Settings = loadQmlLib(new URL("../ui/Settings.js", import.meta.url), ["KEEP_CHOICES"])

const SETTING_DEFAULTS = {
  soundOn: true, sound: "alarm-clock-elapsed", soundFile: "", volume: 100, snoozeMinutes: 9, ringMinutes: 5,
  historyDays: 0
}

function settingsOf(path) {
  return Db.parseSettings(sync(path).settings)
}

// A settings patch as ItemsDb.setSettings sends it.
function setSettings(path, patch) {
  return run(path, "settings.set", { values: Db.settingsCells(patch) })
}

test("a new file has one settings row with the defaults, and the read carries the file's size", (t) => {
  const path = newDb(t)
  assert.equal(rows(path, "SELECT COUNT(*) AS n FROM settings")[0].n, 1)
  const read = settingsOf(path)
  assert.deepEqual(read.settings, SETTING_DEFAULTS)
  assert.equal(read.bytes, readFileSync(path).length)
})

test("a database from before versioning gains the settings row with the defaults", (t) => {
  assert.deepEqual(settingsOf(v0Db(t)).settings, SETTING_DEFAULTS)
})

test("the defaults of SETTINGS are the DEFAULTs of the settings table", (t) => {
  const path = newDb(t)
  cli(path, ["DELETE FROM settings", "INSERT INTO settings (id) VALUES (1)"])
  const cells = sync(path).settings
  for (const [key, spec] of Object.entries(Db.SETTINGS)) {
    assert.equal(cells[spec.column], spec.kind === "bool" ? (spec.fallback ? 1 : 0) : spec.fallback, key)
  }
})

test("every whole number SETTINGS takes, the schema takes, and one past either end it refuses", (t) => {
  const path = newDb(t)
  for (const [key, spec] of Object.entries(Db.SETTINGS)) {
    if (spec.kind !== "int") continue
    for (const value of [spec.min, spec.max]) assert.equal(setSettings(path, { [key]: value }).err, undefined, key + " " + value)
    for (const value of [spec.min - 1, spec.max + 1]) {
      assert.equal(run(path, "settings.set", { values: { [spec.column]: value } }).err, "refused", key + " " + value)
      assert.throws(() => Db.settingsCells({ [key]: value }), /invalid setting/)
    }
  }
})

test("the settings table refuses a second row and values out of range written with sqlite3", (t) => {
  const path = newDb(t)
  for (const sql of ["INSERT INTO settings (id) VALUES (2)", "UPDATE settings SET volume = 101", "UPDATE settings SET volume = -1",
    "UPDATE settings SET snooze_minutes = 0", "UPDATE settings SET ring_minutes = 61", "UPDATE settings SET sound_on = 2",
    "UPDATE settings SET history_days = -1", "UPDATE settings SET history_days = 7", "UPDATE settings SET check_updates = 2"]) {
    assert.throws(() => cli(path, sql), /CHECK constraint failed/, sql)
  }
  assert.deepEqual(settingsOf(path).settings, SETTING_DEFAULTS)
})

test("a settings write sets only the keys it is given, and sending it twice leaves the same row", (t) => {
  const path = newDb(t)
  const patch = { volume: 40, soundOn: false, sound: "custom", soundFile: "/home/me/it's here.ogg" }
  setSettings(path, patch)
  setSettings(path, patch)
  setSettings(path, { snoozeMinutes: 12 })
  assert.deepEqual(settingsOf(path).settings, { ...SETTING_DEFAULTS, ...patch, snoozeMinutes: 12 })
  assert.equal(rows(path, "SELECT COUNT(*) AS n FROM settings")[0].n, 1)
})

test("a settings write brings a row deleted by hand back, and the read shows the defaults until then", (t) => {
  const path = newDb(t)
  cli(path, "DELETE FROM settings")
  assert.deepEqual(settingsOf(path).settings, SETTING_DEFAULTS, "no row reads as the defaults")
  assert.ok(settingsOf(path).bytes > 0, "and still carries the size")
  setSettings(path, { ringMinutes: 7 })
  assert.deepEqual(settingsOf(path).settings, { ...SETTING_DEFAULTS, ringMinutes: 7 })
})

test("the settings row takes the Keep choices, the same ones the page offers", (t) => {
  const path = newDb(t)
  for (const days of Db.SETTINGS.historyDays.options) assert.equal(setSettings(path, { historyDays: days }).err, undefined, String(days))
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

test("settingsCells names an unknown key", () => {
  assert.throws(() => Db.settingsCells({ volume: 50, colour: "red" }), /^Error: unknown setting: colour$/)
})

test("settingsCells refuses an unknown key, a value outside its spec and an empty patch before a spawn", () => {
  for (const patch of [{ colour: "red" }, { volume: -1 }, { volume: 101 }, { volume: 50.5 }, { volume: "50" },
    { snoozeMinutes: 0 }, { ringMinutes: 61 }, { historyDays: 7 }, { soundOn: 1 }, { checkUpdates: "yes" },
    { sound: 3 }, { soundFile: null }, {}]) {
    assert.throws(() => Db.settingsCells(patch), /setting/, JSON.stringify(patch))
  }
})

test("settingsCells keys the patch by column, a switch as 0 or 1", () => {
  assert.deepEqual(Db.settingsCells({ soundOn: false, volume: 40, sound: "bell", historyDays: 30 }),
    { sound_on: 0, volume: 40, sound: "bell", history_days: 30 })
})

test("parseSettings turns a row a hand edit left out of range into settings settingsCells accepts", () => {
  const row = { id: 1, sound_on: 0, sound: "bell", sound_file: "", volume: 250, snooze_minutes: 0,
    ring_minutes: 6.4, history_days: 7, check_updates: 5, db_bytes: 12288 }
  const read = Db.parseSettings(row)
  assert.deepEqual(read, {
    settings: { ...SETTING_DEFAULTS, soundOn: false, sound: "bell", volume: 100, snoozeMinutes: 1, ringMinutes: 6 },
    bytes: 12288
  })
  assert.doesNotThrow(() => Db.settingsCells(read.settings))
  assert.deepEqual(Db.parseSettings(null), { settings: SETTING_DEFAULTS, bytes: 0 }, "a view not read yet has the defaults")
})

test("mergeSettings lays a patch over the settings without changing them in place", () => {
  const base = Db.parseSettings(null).settings
  const merged = Db.mergeSettings(base, { volume: 30, soundOn: false })
  assert.deepEqual(merged, { ...SETTING_DEFAULTS, volume: 30, soundOn: false })
  assert.deepEqual(base, SETTING_DEFAULTS)
})

const DAY = 86400

// History entries aged `days` from now, as the prune measures them.
function agedHistory(path, days) {
  const now = Math.floor(Date.now() / 1000)
  cli(path, "INSERT INTO history (type, title, action, ts) VALUES "
    + days.map((d) => "('note', 'aged " + d + "', 'added', " + (now - d * DAY) + ")").join(", "))
}
function historyTitles(path) {
  return rows(path, "SELECT title FROM history ORDER BY ts DESC").map((r) => r.title)
}

test("keeping 30 days removes, in the same write, only the entries older than 30 days", (t) => {
  const path = newDb(t)
  agedHistory(path, [1, 29, 31, 95])
  run(path, "settings.set", { values: Db.settingsCells({ historyDays: 30 }) }, { at: Db.now() })
  assert.deepEqual(historyTitles(path), ["aged 1", "aged 29"])
  assert.equal(settingsOf(path).settings.historyDays, 30)
})

test("keeping entries forever removes none", (t) => {
  const path = newDb(t)
  agedHistory(path, [1, 400])
  run(path, "settings.set", { values: Db.settingsCells({ historyDays: 0 }) }, { at: Db.now() })
  assert.deepEqual(historyTitles(path), ["aged 1", "aged 400"])
})

test("a prune with nothing past the cutoff leaves the file untouched, so no watcher fires", async (t) => {
  const path = newDb(t)
  agedHistory(path, [1, 10])
  const before = readFileSync(path)
  const mtime = statSync(path).mtimeMs
  await sleep(20)
  assert.equal(run(path, "history.prune", { days: 30 }, { at: Db.now() }).err, undefined)
  assert.deepEqual(readFileSync(path), before)
  assert.equal(statSync(path).mtimeMs, mtime)
  assert.throws(() => Db.wholeIn(0, 1, 36500), /invalid value/)
})

test("the counts carry the oldest history entry, for the prune on open", (t) => {
  const path = newDb(t)
  const now = Math.floor(Date.now() / 1000)
  agedHistory(path, [3, 40])
  assert.equal(Db.parseCounts(sync(path).counts).oldestHistory, now - 40 * DAY)
})

test("prunes: only a Keep of some days with an entry older than them removes anything", () => {
  const now = T0
  assert.equal(Db.prunes(30, now - 31 * DAY, now), true)
  assert.equal(Db.prunes(30, now - 29 * DAY, now), false)
  assert.equal(Db.prunes(0, now - 400 * DAY, now), false, "forever keeps everything")
  assert.equal(Db.prunes(30, 0, now), false, "an empty history has nothing to remove")
})
