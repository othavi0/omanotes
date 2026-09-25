process.env.TZ = "America/Sao_Paulo"

import { test } from "node:test"
import assert from "node:assert/strict"
import { loadQmlLib } from "./lib/load-qml-lib.mjs"

const A = loadQmlLib(new URL("../data/Alarm.js", import.meta.url), [
  "GRACE_MS", "MAX_AUTO_SNOOZES", "DEFAULT_SNOOZE_MINUTES", "DEFAULT_RING_SECONDS",
  "normalizeDays", "isRepeating", "occurrenceAfter", "occurrenceAtOrBefore",
  "alarmNextAt", "alarmDue", "nextAlarm", "tick", "snoozePatch", "expire"
])

const MIN = 60 * 1000

function at(dayOffset, hour, minute) {
  return new Date(2026, 8, 4 + dayOffset, hour, minute, 0, 0).getTime()
}

// Friday 2026-09-04 14:00 local.
const NOW = at(0, 14, 0)

function alarm(patch) {
  return Object.assign({ id: "a1", hour: 7, minute: 30, days: [], enabled: true, snoozedUntil: 0, lastFiredAt: 0, armedAt: 0, autoSnoozes: 0 }, patch)
}

function apply(a, patches) {
  const mine = patches.find(p => p.id === a.id)
  return mine ? Object.assign({}, a, mine.patch) : a
}

test("the constants hold the product defaults", () => {
  assert.equal(A.GRACE_MS, 10 * MIN)
  assert.equal(A.MAX_AUTO_SNOOZES, 3)
  assert.equal(A.DEFAULT_SNOOZE_MINUTES, 9)
  assert.equal(A.DEFAULT_RING_SECONDS, 300)
})

test("normalizeDays keeps valid weekdays sorted and never turns an empty token into Sunday", () => {
  assert.deepEqual(A.normalizeDays("5,1, 3,1"), [1, 3, 5])
  assert.deepEqual(A.normalizeDays([6, "0", 7, -1, 2.5, "", null]), [0, 6])
  assert.deepEqual(A.normalizeDays(""), [])
  assert.deepEqual(A.normalizeDays(undefined), [])
  assert.equal(A.isRepeating(alarm({ days: [] })), false)
  assert.equal(A.isRepeating(alarm({ days: "1,2" })), true)
  assert.equal(A.isRepeating(alarm({ days: [""] })), false)
})

test("alarm occurrences walk the schedule in local time", () => {
  const once = alarm({ hour: 7, minute: 30 })
  assert.equal(A.occurrenceAfter(once, NOW), at(1, 7, 30), "07:30 has passed today, so tomorrow")
  assert.equal(A.occurrenceAfter(alarm({ hour: 15, minute: 0 }), NOW), at(0, 15, 0))
  assert.equal(A.occurrenceAtOrBefore(once, NOW), at(0, 7, 30))
  assert.equal(A.occurrenceAtOrBefore(alarm({ hour: 15, minute: 0 }), NOW), at(-1, 15, 0))
  assert.equal(A.occurrenceAtOrBefore(alarm({ hour: 14, minute: 0 }), NOW), NOW, "at or before includes the instant itself")
  assert.equal(A.occurrenceAfter(alarm({ hour: 14, minute: 0 }), NOW), at(1, 14, 0), "after excludes the instant itself")
  assert.equal(A.occurrenceAfter(alarm({ days: [1, 2, 3, 4, 5] }), NOW), at(3, 7, 30), "weekdays from Friday afternoon land on Monday")
  assert.equal(A.occurrenceAtOrBefore(alarm({ days: [0, 6] }), NOW), at(-5, 7, 30), "last Sunday")
  assert.equal(A.occurrenceAfter(alarm({ days: [6] }), NOW), at(1, 7, 30), "Saturday")
})

test("a weekly alarm whose time has passed today looks a full week ahead and behind", () => {
  assert.equal(A.occurrenceAfter(alarm({ days: [5] }), NOW), at(7, 7, 30), "next Friday")
  assert.equal(A.occurrenceAtOrBefore(alarm({ hour: 15, minute: 0, days: [5] }), NOW), at(-7, 15, 0), "last Friday")
})

test("a freshly created alarm never fires for an occurrence already behind it", () => {
  const created = alarm({ armedAt: NOW })
  assert.equal(A.alarmDue(created, NOW), null)
  assert.equal(A.alarmDue(created, NOW + 5 * MIN), null)
  assert.equal(A.alarmNextAt(created, NOW), at(1, 7, 30))
  assert.deepEqual(A.alarmDue(created, at(1, 7, 30)), { at: at(1, 7, 30), kind: "scheduled" })
  const soon = alarm({ hour: 14, minute: 1, armedAt: NOW + 30 * 1000 })
  assert.equal(A.alarmDue(soon, NOW + 45 * 1000), null, "created 30 s before its own time, silent until then")
  assert.deepEqual(A.alarmDue(soon, at(0, 14, 1)), { at: at(0, 14, 1), kind: "scheduled" })
})

test("an occurrence fires once, then the schedule moves on", () => {
  const fired = alarm({ days: [1, 2, 3, 4, 5], armedAt: at(-3, 12, 0), lastFiredAt: at(0, 7, 30) })
  assert.equal(A.alarmDue(fired, NOW), null)
  assert.equal(A.alarmNextAt(fired, NOW), at(3, 7, 30))
  const missed = alarm({ days: [1, 2, 3, 4, 5], armedAt: at(-3, 12, 0), lastFiredAt: at(-1, 7, 30) })
  assert.deepEqual(A.alarmDue(missed, NOW), { at: at(0, 7, 30), kind: "scheduled" }, "today's ring is still owed")
  assert.ok(NOW - A.alarmDue(missed, NOW).at > A.GRACE_MS, "and it is too old to ring now")
})

test("snooze outranks the schedule and works on a disabled one-shot", () => {
  const snoozed = alarm({ enabled: false, snoozedUntil: NOW + 9 * MIN, lastFiredAt: at(0, 7, 30) })
  assert.equal(A.alarmNextAt(snoozed, NOW), NOW + 9 * MIN)
  assert.equal(A.alarmDue(snoozed, NOW), null)
  assert.deepEqual(A.alarmDue(snoozed, NOW + 9 * MIN), { at: NOW + 9 * MIN, kind: "snooze" })
  assert.equal(A.alarmNextAt(alarm({ enabled: false }), NOW), 0)
  assert.equal(A.alarmDue(alarm({ enabled: false, armedAt: at(-1, 12, 0) }), NOW), null)
})

test("nextAlarm picks the soonest across alarms", () => {
  const list = [
    alarm({ id: "a", hour: 22, minute: 0, armedAt: NOW }),
    alarm({ id: "b", hour: 16, minute: 45, armedAt: NOW }),
    alarm({ id: "c", enabled: false })
  ]
  const next = A.nextAlarm(list, NOW)
  assert.equal(next.alarm.id, "b")
  assert.equal(next.at, at(0, 16, 45))
  assert.equal(A.nextAlarm([], NOW), null)
  assert.equal(A.nextAlarm([alarm({ enabled: false })], NOW), null)
})

test("tick disables a one-shot alarm 11 minutes late, consumes it and reports it missed", () => {
  const late = alarm({ hour: 13, minute: 49, armedAt: at(-1, 12, 0), autoSnoozes: 2 })
  assert.deepEqual(A.tick([late], NOW), {
    patches: [{ id: "a1", patch: { snoozedUntil: 0, lastFiredAt: at(0, 13, 49), autoSnoozes: 0, enabled: false } }],
    ring: [],
    missed: [{ id: "a1", at: at(0, 13, 49), kind: "scheduled" }]
  })
})

test("tick rings a one-shot alarm exactly at the edge of the grace window", () => {
  const edge = alarm({ hour: 13, minute: 50, armedAt: at(-1, 12, 0) })
  assert.deepEqual(A.tick([edge], NOW), {
    patches: [{ id: "a1", patch: { snoozedUntil: 0, lastFiredAt: at(0, 13, 50), autoSnoozes: 0, enabled: false } }],
    ring: [{ id: "a1", at: at(0, 13, 50), kind: "scheduled" }],
    missed: []
  })
})

test("tick leaves a repeating alarm enabled when it fires", () => {
  const daily = alarm({ hour: 14, minute: 0, days: [0, 1, 2, 3, 4, 5, 6], armedAt: at(-1, 12, 0) })
  const result = A.tick([daily], NOW)
  assert.deepEqual(result.patches, [{ id: "a1", patch: { snoozedUntil: 0, lastFiredAt: NOW, autoSnoozes: 0 } }])
  assert.deepEqual(result.ring, [{ id: "a1", at: NOW, kind: "scheduled" }])
})

test("a due snooze only clears snoozedUntil, even on a disabled one-shot", () => {
  const snoozed = alarm({ enabled: false, snoozedUntil: NOW - MIN, lastFiredAt: at(0, 7, 30), autoSnoozes: 2 })
  assert.deepEqual(A.tick([snoozed], NOW), {
    patches: [{ id: "a1", patch: { snoozedUntil: 0 } }],
    ring: [{ id: "a1", at: NOW - MIN, kind: "snooze" }],
    missed: []
  })
})

test("tick patches nothing for alarms that owe nothing and keeps each alarm's result apart", () => {
  const quiet = alarm({ id: "quiet", armedAt: NOW })
  const ringing = alarm({ id: "ring", hour: 13, minute: 55, armedAt: at(-1, 12, 0), days: [5] })
  const old = alarm({ id: "old", hour: 9, minute: 0, armedAt: at(-1, 12, 0) })
  const result = A.tick([quiet, ringing, old], NOW)
  assert.deepEqual(result.patches.map(p => p.id), ["ring", "old"])
  assert.deepEqual(result.ring, [{ id: "ring", at: at(0, 13, 55), kind: "scheduled" }])
  assert.deepEqual(result.missed, [{ id: "old", at: at(0, 9, 0), kind: "scheduled" }])
  assert.deepEqual(A.tick([], NOW), { patches: [], ring: [], missed: [] })
})

test("five days away, returning at 18:00, owes one occurrence: today's 16:30, 90 minutes late", () => {
  const daily = alarm({ hour: 16, minute: 30, days: [0, 1, 2, 3, 4, 5, 6], armedAt: at(-10, 12, 0), lastFiredAt: at(-5, 16, 30) })
  const back = at(0, 18, 0)
  const result = A.tick([daily], back)
  assert.deepEqual(result.missed, [{ id: "a1", at: at(0, 16, 30), kind: "scheduled" }])
  assert.equal(back - result.missed[0].at, 90 * MIN)
  assert.deepEqual(result.ring, [])
  const after = apply(daily, result.patches)
  assert.deepEqual(A.tick([after], back), { patches: [], ring: [], missed: [] }, "the missed occurrence is consumed")
  assert.equal(A.alarmNextAt(after, back), at(1, 16, 30))
})

test("a manual snooze resets autoSnoozes to 0 and an automatic one adds 1", () => {
  const tired = alarm({ autoSnoozes: 3 })
  assert.deepEqual(A.snoozePatch(tired, 9, false, NOW), { snoozedUntil: NOW + 9 * MIN, autoSnoozes: 0 })
  assert.deepEqual(A.snoozePatch(alarm({ autoSnoozes: 1 }), 15, true, NOW), { snoozedUntil: NOW + 15 * MIN, autoSnoozes: 2 })
})

test("a snooze length outside 1 to 180 minutes falls back to the default", () => {
  for (const minutes of [0, 181, -5, NaN, undefined, "x"]) {
    assert.equal(A.snoozePatch(alarm(), minutes, false, NOW).snoozedUntil, NOW + 9 * MIN, String(minutes))
  }
  assert.equal(A.snoozePatch(alarm(), 1, false, NOW).snoozedUntil, NOW + MIN)
  assert.equal(A.snoozePatch(alarm(), 180, false, NOW).snoozedUntil, NOW + 180 * MIN)
})

test("expire drops events that rang for ringSeconds and snoozes only those alarms", () => {
  const byId = { a: alarm({ id: "a" }), b: alarm({ id: "b" }) }
  const events = [{ id: "a", startedAt: NOW - 300 * 1000 }, { id: "b", startedAt: NOW - 299 * 1000 }]
  assert.deepEqual(A.expire(events, byId, NOW, 300), { keep: [events[1]], snooze: ["a"] })
  assert.deepEqual(A.expire(events, byId, NOW - 1000, 300), { keep: events, snooze: [] })
  assert.deepEqual(A.expire([{ id: "gone", startedAt: NOW - 400 * 1000 }], byId, NOW, 300), { keep: [], snooze: [] }, "a removed alarm expires without a snooze")
})

test("three automatic expirations each schedule a snooze and the fourth does not", () => {
  let a = alarm({ hour: 14, minute: 0, armedAt: at(-1, 12, 0) })
  let clock = NOW
  const snoozedAt = []
  for (let period = 1; period <= 4; period++) {
    const fired = A.tick([a], clock)
    assert.equal(fired.ring.length, 1, "period " + period + " rings")
    a = apply(a, fired.patches)
    const startedAt = clock
    clock = startedAt + A.DEFAULT_RING_SECONDS * 1000
    const out = A.expire([{ id: a.id, startedAt }], { [a.id]: a }, clock, A.DEFAULT_RING_SECONDS)
    assert.deepEqual(out.keep, [])
    if (period < 4) {
      assert.deepEqual(out.snooze, [a.id], "period " + period + " expires into a snooze")
      a = Object.assign({}, a, A.snoozePatch(a, A.DEFAULT_SNOOZE_MINUTES, true, clock))
      assert.equal(a.autoSnoozes, period)
      snoozedAt.push(a.snoozedUntil)
      clock = a.snoozedUntil
    } else {
      assert.deepEqual(out.snooze, [], "the fourth expiration schedules nothing")
    }
  }
  assert.deepEqual(snoozedAt, [NOW + 14 * MIN, NOW + 28 * MIN, NOW + 42 * MIN])
  assert.equal(a.enabled, false)
  assert.equal(A.alarmNextAt(a, clock), 0, "the one-shot has nothing left to ring")
})
