process.env.TZ = "Europe/Copenhagen"

import { test } from "node:test"
import assert from "node:assert/strict"
import { loadQmlLib } from "./lib/load-qml-lib.mjs"

const A = loadQmlLib(new URL("../data/Alarm.js", import.meta.url), [
  "occurrenceAfter", "occurrenceAtOrBefore", "alarmDue", "alarmNextAt"
])

const daily = { id: "d", hour: 2, minute: 30, days: [0, 1, 2, 3, 4, 5, 6], enabled: true, snoozedUntil: 0, lastFiredAt: 0, armedAt: 0, autoSnoozes: 0 }

test("on the spring-forward night a 02:30 alarm, which the clock skips, rings at 03:30 CEST", () => {
  const eve = new Date(2026, 2, 28, 12, 0).getTime()
  const expected = Date.UTC(2026, 2, 29, 1, 30)
  assert.equal(A.occurrenceAfter(daily, eve), expected)
  assert.equal(new Date(expected).getHours(), 3)
  assert.equal(A.occurrenceAtOrBefore(daily, Date.UTC(2026, 2, 29, 1, 29)), Date.UTC(2026, 2, 28, 1, 30), "a minute before it, the owed occurrence is still the previous night")
})

test("on the fall-back night a 02:30 alarm rings on the first 02:30 (CEST) and not again an hour later", () => {
  const armed = Object.assign({}, daily, { armedAt: new Date(2026, 9, 24, 12, 0).getTime() })
  const first = Date.UTC(2026, 9, 25, 0, 30)
  const second = Date.UTC(2026, 9, 25, 1, 30)
  assert.equal(new Date(second).getHours(), 2, "01:30Z is also 02:30 local, in CET")
  assert.equal(A.occurrenceAfter(armed, armed.armedAt), first)
  assert.deepEqual(A.alarmDue(armed, first), { at: first, kind: "scheduled" })
  const fired = Object.assign({}, armed, { lastFiredAt: first })
  assert.equal(A.alarmDue(fired, second), null)
  assert.equal(A.alarmNextAt(fired, second), Date.UTC(2026, 9, 26, 1, 30))
})
