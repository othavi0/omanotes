process.env.TZ = "America/Sao_Paulo"

import { test } from "node:test"
import assert from "node:assert/strict"
import { loadQmlLib } from "./lib/load-qml-lib.mjs"

const A = loadQmlLib(new URL("../data/Alarm.js", import.meta.url), [
  "GRACE_MS", "MAX_AUTO_SNOOZES", "DEFAULT_SNOOZE_MINUTES", "DEFAULT_RING_SECONDS",
  "normalizeDays", "isRepeating", "occurrenceAfter", "occurrenceAtOrBefore",
  "alarmNextAt", "alarmDue", "nextAlarm", "tick", "snoozePatch", "expire",
  "MAX_ALARMS", "MAX_LABEL", "DEFAULT_RING_MINUTES", "MIN_RING_MINUTES", "MAX_RING_MINUTES",
  "ringMinutes", "parseTime", "parseFields", "newAlarm", "editPatch", "enablePatch", "isOn",
  "withPatch", "ringWith", "ringWithout"
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

test("a snooze length is clamped to 1..180 minutes and only a missing or non-numeric one uses the default", () => {
  const cases = [[0, 1], [-5, 1], [181, 180], [1000, 180], [2.6, 3], ["15", 15], [NaN, 9], [undefined, 9], [null, 9], ["", 9], ["x", 9]]
  for (const [minutes, expected] of cases) {
    assert.equal(A.snoozePatch(alarm(), minutes, false, NOW).snoozedUntil, NOW + expected * MIN, String(minutes))
  }
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

// ------------------------------------------------- the service's helpers

const FIELDS = { time: "07:30", label: "Wake up", days: [1, 2, 3, 4, 5], snoozeMinutes: 9, ringMinutes: 5 }

test("the limits hold the product defaults", () => {
  assert.equal(A.MAX_ALARMS, 50)
  assert.equal(A.MAX_LABEL, 40)
  assert.equal(A.DEFAULT_RING_MINUTES, 5)
  assert.equal(A.DEFAULT_RING_SECONDS, A.DEFAULT_RING_MINUTES * 60)
  assert.equal(A.MIN_RING_MINUTES, 1)
  assert.equal(A.MAX_RING_MINUTES, 60)
})

test("ringMinutes is clamped to 1..60 and only a missing or non-numeric one uses the default", () => {
  const cases = [[0, 1], [-5, 1], [61, 60], [1000, 60], [2.6, 3], ["15", 15], [NaN, 5], [undefined, 5], [null, 5], ["", 5], ["x", 5]]
  for (const [minutes, expected] of cases) assert.equal(A.ringMinutes(minutes), expected, String(minutes))
})

test("parseTime reads a 24-hour clock with or without the colon and refuses anything else", () => {
  assert.deepEqual(A.parseTime("07:30"), { hour: 7, minute: 30 })
  assert.deepEqual(A.parseTime("0730"), { hour: 7, minute: 30 })
  assert.deepEqual(A.parseTime("7:30"), { hour: 7, minute: 30 })
  assert.deepEqual(A.parseTime(" 23:59 "), { hour: 23, minute: 59 })
  assert.deepEqual(A.parseTime("0:00"), { hour: 0, minute: 0 })
  for (const text of ["24:00", "23:60", "7:3", "730x", "", "   ", "7", "1:2:3", null, undefined, "07:30 pm"]) {
    assert.equal(A.parseTime(text), null, String(text))
  }
})

test("parseFields turns editor input into fields, clamps the minutes, trims and caps the label and cleans its control characters", () => {
  assert.deepEqual(A.parseFields(FIELDS), { hour: 7, minute: 30, label: "Wake up", days: [1, 2, 3, 4, 5], snoozeMinutes: 9, ringMinutes: 5 })
  const long = "x".repeat(60)
  const messy = A.parseFields({ time: "0730", label: "  a\tb\nc " + long, days: "5,1,5", snoozeMinutes: 500, ringMinutes: 0 })
  assert.equal(messy.label.length, A.MAX_LABEL)
  assert.equal(messy.label.slice(0, 5), "a b c")
  assert.deepEqual(messy.days, [1, 5])
  assert.equal(messy.snoozeMinutes, 180)
  assert.equal(messy.ringMinutes, 1)
  assert.deepEqual(A.parseFields({ time: "7:30" }), { hour: 7, minute: 30, label: "", days: [], snoozeMinutes: 9, ringMinutes: 5 })
  assert.equal(A.parseFields({ time: "25:00", label: "x" }), null)
  assert.equal(A.parseFields({ label: "x" }), null)
})

test("newAlarm is an enabled record armed now with nothing consumed and no id", () => {
  const fields = A.parseFields(FIELDS)
  assert.deepEqual(A.newAlarm(fields, NOW), {
    hour: 7, minute: 30, label: "Wake up", days: [1, 2, 3, 4, 5], enabled: true, snoozeMinutes: 9, ringMinutes: 5,
    snoozedUntil: 0, lastFiredAt: 0, armedAt: NOW, autoSnoozes: 0
  })
  assert.equal(A.alarmDue(A.newAlarm(A.parseFields({ time: "13:00" }), NOW), NOW), null, "an occurrence before its creation is not owed")
})

test("editPatch re-arms only when the hour, the minute or the days change", () => {
  const a = alarm({ label: "Old", days: [1, 3], armedAt: at(-1, 12, 0), snoozedUntil: NOW + 5 * MIN, enabled: false, snoozeMinutes: 9, ringMinutes: 5, autoSnoozes: 2 })
  const same = { hour: 7, minute: 30, label: "New", days: [3, 1], snoozeMinutes: 15, ringMinutes: 2 }
  assert.deepEqual(A.editPatch(a, same, NOW), { hour: 7, minute: 30, label: "New", days: [1, 3], snoozeMinutes: 15, ringMinutes: 2 },
    "a label or minutes change keeps the arm, the snooze and the switch")
  for (const changed of [{ ...same, hour: 8 }, { ...same, minute: 31 }, { ...same, days: [1, 3, 5] }, { ...same, days: [] }]) {
    const patch = A.editPatch(a, changed, NOW)
    assert.equal(patch.armedAt, NOW, JSON.stringify(changed))
    assert.equal(patch.snoozedUntil, 0)
    assert.equal(patch.enabled, true)
    assert.equal(patch.autoSnoozes, 0)
  }
})

test("enablePatch arms an alarm that is switched on and quiets one that is switched off", () => {
  const a = alarm({ enabled: false, snoozedUntil: NOW + 5 * MIN, armedAt: at(-1, 12, 0), autoSnoozes: 2 })
  assert.deepEqual(A.enablePatch(a, true, NOW), { enabled: true, armedAt: NOW, snoozedUntil: 0, autoSnoozes: 0 })
  assert.deepEqual(A.enablePatch(alarm({ snoozedUntil: NOW + 5 * MIN }), false, NOW), { enabled: false, snoozedUntil: 0 })
  assert.equal(A.alarmDue(A.withPatch(alarm({ armedAt: at(-1, 12, 0) }), A.enablePatch(a, true, NOW)), NOW), null,
    "switching on does not ring the occurrence that passed while it was off")
})

test("isOn is the switch: enabled, or snoozed into the future", () => {
  assert.equal(A.isOn(alarm(), NOW), true)
  assert.equal(A.isOn(alarm({ enabled: false }), NOW), false)
  assert.equal(A.isOn(alarm({ enabled: false, snoozedUntil: NOW + 1 }), NOW), true)
  assert.equal(A.isOn(alarm({ enabled: false, snoozedUntil: NOW }), NOW), false)
  assert.equal(A.isOn(null, NOW), false)
})

test("withPatch returns a new record and leaves the old one alone", () => {
  const a = alarm()
  const b = A.withPatch(a, { enabled: false, label: "x" })
  assert.equal(b.enabled, false)
  assert.equal(b.label, "x")
  assert.equal(a.enabled, true)
  assert.equal(b.hour, 7)
})

test("ringWith adds new events at nowMs, ignores an id already on the card and keeps the card's first startedAt", () => {
  const first = A.ringWith(null, ["a"], NOW)
  assert.deepEqual(first, { startedAt: NOW, events: [{ id: "a", startedAt: NOW }] })
  const second = A.ringWith(first, ["a", "b"], NOW + 3000)
  assert.deepEqual(second, { startedAt: NOW, events: [{ id: "a", startedAt: NOW }, { id: "b", startedAt: NOW + 3000 }] })
  assert.deepEqual(first.events.length, 1, "the old state is not changed in place")
  assert.equal(A.ringWith(null, [], NOW), null)
  assert.deepEqual(A.ringWith(first, [], NOW + 1), first)
})

test("ringWithout takes one event off the card and the card goes away with its last event", () => {
  const ring = A.ringWith(A.ringWith(null, ["a"], NOW), ["b"], NOW + 1000)
  assert.deepEqual(A.ringWithout(ring, "a"), { startedAt: NOW, events: [{ id: "b", startedAt: NOW + 1000 }] })
  assert.equal(A.ringWithout(A.ringWithout(ring, "a"), "b"), null)
  assert.deepEqual(A.ringWithout(ring, "zzz"), ring)
  assert.equal(A.ringWithout(null, "a"), null)
})

test("expire uses each alarm's own ring length and drops an event whose alarm is gone without a snooze", () => {
  const byId = { short: alarm({ id: "short", ringMinutes: 1 }), long: alarm({ id: "long", ringMinutes: 10 }) }
  const events = [{ id: "short", startedAt: NOW - 60 * 1000 }, { id: "long", startedAt: NOW - 60 * 1000 }, { id: "gone", startedAt: NOW - 3600 * 1000 }]
  assert.deepEqual(A.expire(events, byId, NOW), { keep: [events[1]], snooze: ["short"] })
  assert.deepEqual(A.expire(events, byId, NOW - 1000), { keep: [events[0], events[1]], snooze: [] })
  assert.deepEqual(A.expire(events, byId, NOW + 9 * MIN), { keep: [], snooze: ["short", "long"] })
  const tired = { short: alarm({ id: "short", ringMinutes: 1, autoSnoozes: A.MAX_AUTO_SNOOZES }) }
  assert.deepEqual(A.expire([events[0]], tired, NOW), { keep: [], snooze: [] }, "the fourth expiry earns no snooze")
})
