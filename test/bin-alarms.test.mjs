// What the alarm writes and the alarm rows of the snapshot do, through the
// binary and the coercion of data/Db.js (ADR-0015).
import { test } from "node:test"
import assert from "node:assert/strict"
import { Db, T0, cli, newDb, rows, run, seeded, sync } from "./lib/bin-fixture.mjs"

function ids(list) {
  return list.map((r) => r.id)
}

function alarmRecord(patch) {
  return {
    hour: 7, minute: 30, label: "Wake up", days: [1, 2, 3, 4, 5], enabled: true, snoozeMinutes: 9, ringMinutes: 5,
    snoozedUntil: 0, lastFiredAt: 0, armedAt: T0 * 1000, autoSnoozes: 0, ...patch
  }
}

const ALARM_ROWS = "SELECT id, hour, minute, label, days, enabled, snooze_minutes, ring_minutes,"
  + " snoozed_until_ms, last_fired_at_ms, armed_at_ms, auto_snoozes FROM alarms ORDER BY id"

// An alarm write as the service's AlarmsDb sends it.
function insert(path, record) {
  return run(path, "alarm.insert", { alarm: Db.alarmCells(record) }, { by: "service" })
}
function save(path, record) {
  return run(path, "alarm.save", { id: Db.wholeId(record.id), alarm: Db.alarmCells(record) }, { by: "service" })
}
function remove(path, id) {
  return run(path, "alarm.delete", { id }, { by: "service" })
}

function tables(path) {
  return { items: rows(path, "SELECT * FROM items ORDER BY id"), history: rows(path, "SELECT * FROM history ORDER BY id") }
}

test("the alarms table refuses a 41-character label, the one limit the record's checks leave to it", (t) => {
  const path = newDb(t)
  const result = insert(path, alarmRecord({ label: "x".repeat(41) }))
  assert.equal(result.err, "refused")
  assert.match(result.detail, /CHECK constraint failed/)
  assert.ok(insert(path, alarmRecord({ label: "x".repeat(40) })).value > 0)
})

test("a row inserted with sqlite3 is armed at its insert time and takes the defaults", (t) => {
  const path = newDb(t)
  const before = Date.now()
  cli(path, "INSERT INTO alarms (hour, minute) VALUES (6, 15)")
  const row = rows(path, ALARM_ROWS)[0]
  assert.deepEqual([row.label, row.days, row.enabled, row.snooze_minutes, row.ring_minutes, row.auto_snoozes], ["", 0, 1, 9, 5, 0])
  assert.ok(row.armed_at_ms >= Math.floor(before / 1000) * 1000 && row.armed_at_ms <= Date.now(), "armed_at_ms " + row.armed_at_ms)
})

test("an insert stores every field, answers the id and writes no history row", (t) => {
  const path = seeded(t)
  const before = tables(path)
  assert.equal(insert(path, alarmRecord({ label: "Jane's pills", days: [0, 6], enabled: false, snoozedUntil: 5, lastFiredAt: 6, autoSnoozes: 2 })).value, 1)
  assert.deepEqual(rows(path, ALARM_ROWS), [{
    id: 1, hour: 7, minute: 30, label: "Jane's pills", days: 65, enabled: 0, snooze_minutes: 9, ring_minutes: 5,
    snoozed_until_ms: 5, last_fired_at_ms: 6, armed_at_ms: T0 * 1000, auto_snoozes: 2
  }])
  assert.deepEqual(tables(path), before)
  assert.equal(insert(path, alarmRecord()).value, 2)
})

test("the snapshot lists the alarms by time of day, then id, as records", (t) => {
  const path = newDb(t)
  insert(path, alarmRecord({ hour: 22, minute: 0 }))
  insert(path, alarmRecord({ hour: 7, minute: 45 }))
  insert(path, alarmRecord({ hour: 7, minute: 30, label: "Wake up", days: [0, 6] }))
  insert(path, alarmRecord({ hour: 7, minute: 30 }))
  const alarms = Db.parseAlarms(sync(path).alarms)
  assert.deepEqual(ids(alarms), [3, 4, 2, 1])
  assert.deepEqual(alarms[0], {
    id: 3, hour: 7, minute: 30, label: "Wake up", days: [0, 6], enabled: true, snoozeMinutes: 9, ringMinutes: 5,
    snoozedUntil: 0, lastFiredAt: 0, armedAt: T0 * 1000, autoSnoozes: 0
  })
})

test("a save writes every column, and sending it twice leaves one identical row", (t) => {
  const path = newDb(t)
  const id = insert(path, alarmRecord()).value
  const record = alarmRecord({ id, hour: 8, minute: 5, label: "Gym", days: [1, 3, 5], enabled: false, snoozeMinutes: 10,
    ringMinutes: 2, snoozedUntil: 11, lastFiredAt: 12, armedAt: 13, autoSnoozes: 3 })
  assert.equal(save(path, record).err, undefined)
  const once = rows(path, ALARM_ROWS)
  assert.deepEqual(once, [{
    id, hour: 8, minute: 5, label: "Gym", days: 42, enabled: 0, snooze_minutes: 10, ring_minutes: 2,
    snoozed_until_ms: 11, last_fired_at_ms: 12, armed_at_ms: 13, auto_snoozes: 3
  }])
  assert.equal(save(path, record).err, undefined)
  assert.deepEqual(rows(path, ALARM_ROWS), once)
})

test("a column the file has beyond the eleven of the protocol keeps its DEFAULT, and one the protocol lacks is refused", (t) => {
  const path = newDb(t)
  // A schema from a later release, or the user, added a column.
  cli(path, "ALTER TABLE alarms ADD COLUMN sound TEXT NOT NULL DEFAULT 'bell'")
  const id = insert(path, alarmRecord()).value
  assert.ok(id > 0, "the insert of the eleven columns goes through")
  cli(path, `UPDATE alarms SET sound = 'chime' WHERE id = ${id}`)
  assert.equal(save(path, alarmRecord({ id, hour: 9 })).err, undefined, "and so does the save")
  assert.deepEqual(rows(path, "SELECT hour, sound FROM alarms"), [{ hour: 9, sound: "chime" }], "the save leaves the column it does not name")
  const extra = run(path, "alarm.insert", { alarm: { ...Db.alarmCells(alarmRecord()), sound: "horn" } }, { by: "service" })
  assert.deepEqual(extra, { id: 1, err: "bad_request", detail: "unknown or repeated column" }, "a column outside the protocol is refused even when the file has it")
  assert.equal(rows(path, "SELECT count(*) AS n FROM alarms")[0].n, 1)
})

test("a save and a delete of a missing id are not_found and write nothing", (t) => {
  const path = seeded(t)
  insert(path, alarmRecord())
  const before = { alarms: rows(path, ALARM_ROWS), ...tables(path) }
  assert.equal(save(path, alarmRecord({ id: 99 })).err, "not_found")
  assert.equal(remove(path, 99).err, "not_found")
  assert.deepEqual({ alarms: rows(path, ALARM_ROWS), ...tables(path) }, before)
  assert.equal(remove(path, 1).err, undefined)
  assert.deepEqual(rows(path, ALARM_ROWS), [])
  assert.deepEqual(tables(path), { items: before.items, history: before.history })
})

test("alarmCells refuses a field out of range before a spawn", () => {
  assert.throws(() => Db.alarmCells(alarmRecord({ hour: 24 })), { message: "invalid value: 24" })
  assert.throws(() => Db.alarmCells(alarmRecord({ minute: -1 })), { message: "invalid value: -1" })
  assert.throws(() => Db.alarmCells(alarmRecord({ ringMinutes: 61 })), { message: "invalid value: 61" })
  assert.throws(() => Db.wholeId("abc"), { message: "invalid id: abc" })
  assert.throws(() => Db.wholeId("1; DROP TABLE alarms"), { message: /invalid id/ })
})

test("parseAlarms turns a row a hand edit left out of range into one alarmCells accepts, and drops one it cannot read", (t) => {
  const path = newDb(t)
  cli(path, "INSERT INTO alarms (id, hour, minute, label, days, enabled, snooze_minutes, ring_minutes,"
    + " snoozed_until_ms, last_fired_at_ms, armed_at_ms, auto_snoozes) VALUES"
    + " (1, 6.4, 29.6, 'Hand', 3, 1, 9.5, 1.4, -1, 1700000000000.5, -3.2, 2.7),"
    + " (2, 7, 0, 'Plain', 0, 1, 9, 5, 0, 0, 0, 0)")
  const alarms = Db.parseAlarms(sync(path).alarms)
  assert.deepEqual(alarms[0], {
    id: 1, hour: 6, minute: 30, label: "Hand", days: [0, 1], enabled: true, snoozeMinutes: 10, ringMinutes: 1,
    snoozedUntil: 0, lastFiredAt: 1700000000001, armedAt: 0, autoSnoozes: 3
  })
  for (const alarm of alarms) {
    assert.doesNotThrow(() => Db.alarmCells(alarm), "row " + alarm.id + " can be written back")
  }
  const unreadable = [
    { id: 3, hour: "x", minute: 0, label: "", days: 0, enabled: 1, snooze_minutes: 9, ring_minutes: 5,
      snoozed_until_ms: 0, last_fired_at_ms: 0, armed_at_ms: 0, auto_snoozes: 0 },
    { id: 0, hour: 7, minute: 0, label: "", days: 0, enabled: 1, snooze_minutes: 9, ring_minutes: 5,
      snoozed_until_ms: 0, last_fired_at_ms: 0, armed_at_ms: 0, auto_snoozes: 0 },
    { id: 4, hour: 30, minute: 75, label: "", days: 0, enabled: 1, snooze_minutes: 900, ring_minutes: 90,
      snoozed_until_ms: 0, last_fired_at_ms: 0, armed_at_ms: 0, auto_snoozes: 500 }
  ]
  assert.deepEqual(Db.parseAlarms(unreadable).map((a) => [a.id, a.hour, a.minute, a.snoozeMinutes, a.ringMinutes, a.autoSnoozes]),
    [[4, 23, 59, 180, 60, 99]], "an unreadable hour and a non-positive id are dropped, the rest is clamped")
  assert.deepEqual(Db.parseAlarms(null), [])
})

test("mergeAlarms lays each pending record over its row, drops a pending null and brings no gone row back", () => {
  const rows = [alarmRecord({ id: 1 }), alarmRecord({ id: 2, hour: 9 }), alarmRecord({ id: 3, hour: 10 })]
  const pending = {
    2: { write: 5, record: alarmRecord({ id: 2, hour: 9, enabled: false }), retry: false },
    3: { write: 6, record: null, retry: false },
    4: { write: 7, record: alarmRecord({ id: 4, hour: 11 }), retry: true }
  }
  const merged = Db.mergeAlarms(rows, pending)
  assert.deepEqual(ids(merged), [1, 2])
  assert.equal(merged[1].enabled, false)
  assert.deepEqual(merged[0], rows[0])
  assert.deepEqual(Db.mergeAlarms(rows, {}), rows)
  assert.deepEqual(ids(rows), [1, 2, 3], "the rows are not changed in place")
})

test("daysMask and maskDays turn a getDay() list into a 7-bit mask and back, sorted and unique", () => {
  assert.equal(Db.daysMask([0, 6]), 65)
  assert.equal(Db.daysMask([1, 2, 3, 4, 5]), 62)
  assert.equal(Db.daysMask([5, 1, 5]), 34)
  assert.equal(Db.daysMask([]), 0)
  assert.equal(Db.daysMask([7, -1]), 0)
  assert.deepEqual(Db.maskDays(65), [0, 6])
  assert.deepEqual(Db.maskDays(62), [1, 2, 3, 4, 5])
  assert.deepEqual(Db.maskDays(0), [])
  assert.deepEqual(Db.maskDays("34"), [1, 5])
  assert.deepEqual(Db.maskDays(255), [0, 1, 2, 3, 4, 5, 6])
})
