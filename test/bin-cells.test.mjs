// The snapshot hands back each cell in the storage class `sqlite3 -json`
// printed, so the coercion of data/Db.js (parseSettings, parseAlarms,
// parseCounts) makes of it what the old coercion made of the CLI's text, even
// from a file edited by hand with text, fractions, blobs and infinities in
// number columns.
import test from "node:test"
import assert from "node:assert/strict"
import { Db, Legacy, PROTOCOL, call, cli, exec, run, sync, tempDb, write } from "./lib/bin-fixture.mjs"

const SETTINGS_COLUMNS = ["sound_on", "sound", "sound_file", "volume", "snooze_minutes", "ring_minutes", "history_days", "check_updates"]
const ALARM_COLUMNS = ["hour", "minute", "label", "days", "enabled", "snooze_minutes", "ring_minutes", "snoozed_until_ms", "last_fired_at_ms", "armed_at_ms", "auto_snoozes"]

// SQL for a hostile cell, as a hand edit would leave it.
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

// The CLI prints an infinite REAL as Inf, which no JSON reader takes; the binary sends 9e999.
function cliRows(dbPath, sql) {
  const text = cli(dbPath, sql, { json: true })
  const fixed = text.replace(/:(-?)Inf([,}])/g, ":$19e999$2")
  return { text, rows: fixed.trim() === "" ? [] : JSON.parse(fixed) }
}

const hasInf = (text) => /:-?Inf[,}]/.test(text)

// The old parser over the CLI text: it threw on Inf, which is the defect the binary's 9e999 fixes.
function oldParse(parse, text) {
  try {
    return { value: parse(text) }
  } catch (e) {
    return { threw: e.message }
  }
}

function hostileDb(t) {
  const path = tempDb(t)
  run(path, "alarm.insert", { alarm: { hour: 7, minute: 30, label: "Wake", days: 62, enabled: 1, snooze_minutes: 9, ring_minutes: 5, snoozed_until_ms: 0, last_fired_at_ms: 0, armed_at_ms: 1, auto_snoozes: 0 } }, { by: "service" })
  run(path, "item.add", { type: "note", title: "n", body: "b" })
  return path
}

for (const [name, cell] of Object.entries(HOSTILE)) {
  test(`${name} in every settings and alarm column reads as the CLI read it, and coerces the same`, (t) => {
    const path = hostileDb(t)
    cli(path, ["PRAGMA ignore_check_constraints = ON",
      `UPDATE settings SET ${SETTINGS_COLUMNS.map((c) => `${c} = ${cell}`).join(", ")}`,
      `UPDATE alarms SET ${ALARM_COLUMNS.map((c) => `${c} = ${cell}`).join(", ")}`,
      `UPDATE items SET status = ${cell}, created_at = ${cell}, updated_at = ${cell}, title = ${cell}`,
      `UPDATE history SET ts = ${cell}, action = ${cell}`])
    const snap = sync(path)

    const settings = cliRows(path, Legacy.settingsSql())
    const alarms = cliRows(path, Legacy.alarmsSql())
    const counts = cliRows(path, Legacy.countsSql())
    const items = cliRows(path, Legacy.listSql("all", ""))
    const history = cliRows(path, Legacy.historySql())
    assert.deepEqual(snap.settings, settings.rows[0], "settings cells")
    assert.deepEqual(snap.alarms, alarms.rows, "alarm cells")
    assert.deepEqual(snap.counts, counts.rows[0], "count cells")
    assert.deepEqual(snap.items, items.rows, "item cells")
    assert.deepEqual(snap.history, history.rows, "history cells")

    // The coercion of data/Db.js over the binary's cells, and the old one over the CLI's text.
    const fromBin = {
      settings: Db.parseSettings(snap.settings),
      alarms: Db.parseAlarms(snap.alarms),
      counts: Db.parseCounts(snap.counts)
    }
    const fromCli = {
      settings: oldParse(Legacy.parseSettings, settings.text),
      alarms: oldParse(Legacy.parseAlarms, alarms.text),
      counts: oldParse(Legacy.parseCounts, counts.text)
    }
    for (const key of Object.keys(fromBin)) {
      if (hasInf(key === "settings" ? settings.text : key === "alarms" ? alarms.text : counts.text)) {
        assert.equal(fromCli[key].threw, "unreadable sqlite3 output", `${key}: the old read failed on Inf`)
      } else {
        assert.deepEqual(fromBin[key], fromCli[key].value, key)
      }
    }
  })
}

test("infinity in a number column falls back where the old read failed whole", (t) => {
  const path = hostileDb(t)
  cli(path, ["PRAGMA ignore_check_constraints = ON", "UPDATE settings SET volume = 9e999, snooze_minutes = -9e999", "UPDATE alarms SET snooze_minutes = 9e999, armed_at_ms = 9e999"])
  const raw = exec([PROTOCOL, "run", path], { sync: { since: -1, views: [] } }).stdout
  assert.ok(raw.includes("\"volume\":9e999") && raw.includes("\"snooze_minutes\":-9e999"), "the cells travel as 9e999")
  const snap = JSON.parse(raw.split("\n")[0])
  assert.equal(snap.settings.volume, Infinity)
  const settings = Db.parseSettings(snap.settings).settings
  assert.equal(settings.volume, 100)
  assert.equal(settings.snoozeMinutes, 9)
  const [alarm] = Db.parseAlarms(snap.alarms)
  assert.equal(alarm.snoozeMinutes, 9)
  assert.equal(alarm.armedAt, 0)
})

test("a settings row deleted by hand reads as NULL cells, which fall back to the defaults", (t) => {
  const path = hostileDb(t)
  cli(path, "DELETE FROM settings")
  const snap = sync(path)
  const cells = cliRows(path, Legacy.settingsSql()).rows[0]
  assert.deepEqual(snap.settings, cells)
  assert.equal(snap.settings.volume, null)
  assert.ok(snap.settings.db_bytes > 0)
  assert.deepEqual(Db.parseSettings(snap.settings).settings, Db.parseSettings(null).settings)
  // The next write of a setting brings the row back with the defaults for the rest, as the old upsert did.
  call(path, { writes: [write("settings.set", { values: { volume: 40 } })] })
  assert.equal(Db.parseSettings(sync(path).settings).settings.volume, 40)
})

test("a NUL inside a text travels whole, where the CLI cut the text at it", (t) => {
  const path = hostileDb(t)
  cli(path, "UPDATE items SET title = 'a' || char(0) || 'b', body = NULL")
  const snap = sync(path)
  assert.equal(snap.items[0].title, "a\u0000b")
  assert.equal(snap.items[0].body, null)
  assert.equal(cliRows(path, Legacy.listSql("all", "")).rows[0].title, "a")
})
