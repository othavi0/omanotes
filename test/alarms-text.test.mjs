process.env.TZ = "America/Sao_Paulo"

import { test } from "node:test"
import assert from "node:assert/strict"
import { loadQmlLib } from "./lib/load-qml-lib.mjs"

const T = loadQmlLib(new URL("../ui/Alarms.js", import.meta.url), [
  "WEEK_ORDER", "DAY_LETTERS", "timeText", "dayName", "daysText", "nextText", "nextInText", "nextSummary",
  "rowDetail", "ringTitle", "snoozeLabel", "lateText", "missedText", "ringView"
])

const MIN = 60 * 1000

function at(dayOffset, hour, minute) {
  return new Date(2026, 8, 4 + dayOffset, hour, minute, 0, 0).getTime()
}

// Friday 2026-09-04 14:00 local.
const NOW = at(0, 14, 0)

function alarm(patch) {
  return Object.assign({ id: 1, hour: 7, minute: 30, label: "Wake up", days: [], enabled: true, snoozeMinutes: 9, ringMinutes: 5,
    snoozedUntil: 0, lastFiredAt: 0, armedAt: at(-1, 12, 0), autoSnoozes: 0 }, patch)
}

test("the day chips run Monday first and map back to getDay() indices", () => {
  assert.deepEqual(T.WEEK_ORDER, [1, 2, 3, 4, 5, 6, 0])
  assert.deepEqual(T.DAY_LETTERS, ["M", "T", "W", "T", "F", "S", "S"])
  assert.equal(T.dayName(0), "Sun")
  assert.equal(T.dayName(6), "Sat")
})

test("timeText pads the hour and the minute", () => {
  assert.equal(T.timeText(7, 5), "07:05")
  assert.equal(T.timeText(23, 59), "23:59")
  assert.equal(T.timeText(0, 0), "00:00")
})

test("daysText names the common sets and lists the others in week order", () => {
  assert.equal(T.daysText([]), "once")
  assert.equal(T.daysText([0, 1, 2, 3, 4, 5, 6]), "every day")
  assert.equal(T.daysText([1, 2, 3, 4, 5]), "weekdays")
  assert.equal(T.daysText([0, 6]), "weekends")
  assert.equal(T.daysText([1, 3, 5]), "Mon, Wed, Fri")
  assert.equal(T.daysText([0, 6, 3]), "Wed, Sat, Sun")
  assert.equal(T.daysText([6]), "Sat")
})

test("nextText is the time alone on the same local day and the day plus the time on another", () => {
  assert.equal(T.nextText(at(0, 16, 30), NOW), "16:30")
  assert.equal(T.nextText(at(1, 7, 30), NOW), "Sat 07:30")
  assert.equal(T.nextText(at(0, 23, 59), NOW), "23:59")
  assert.equal(T.nextText(at(1, 0, 0), NOW), "Sat 00:00")
  assert.equal(T.nextText(0, NOW), "")
})

test("nextInText says the day and how long until it, in the largest two units", () => {
  assert.equal(T.nextInText(at(1, 7, 30), NOW), "next Sat, in 17 h 30 min")
  assert.equal(T.nextInText(at(2, 7, 30), NOW), "next Sun, in 1 d 17 h")
  assert.equal(T.nextInText(at(0, 14, 42), NOW), "today, in 42 min")
  assert.equal(T.nextInText(at(0, 16, 28), NOW), "today, in 2 h 28 min")
  assert.equal(T.nextInText(NOW + 30 * 1000, NOW), "today, in 0 min")
  assert.equal(T.nextInText(0, NOW), "")
})

test("nextSummary is the header line", () => {
  assert.equal(T.nextSummary(at(1, 7, 30), NOW), "next alarm Sat 07:30")
  assert.equal(T.nextSummary(at(0, 16, 30), NOW), "next alarm 16:30")
  assert.equal(T.nextSummary(0, NOW), "no alarm set")
})

test("rowDetail is the days, then the state that matters most, with the next ring from Alarm.js", () => {
  assert.equal(T.rowDetail(alarm({ days: [1, 2, 3, 4, 5] }), at(3, 7, 30), NOW), "weekdays · next Mon")
  assert.equal(T.rowDetail(alarm({ days: [0, 1, 2, 3, 4, 5, 6], snoozedUntil: at(0, 14, 11) }), at(0, 14, 11), NOW), "every day · snoozed to 14:11")
  assert.equal(T.rowDetail(alarm({ enabled: false }), 0, NOW), "once · off")
  assert.equal(T.rowDetail(alarm({ hour: 16, minute: 30 }), at(0, 16, 30), NOW), "once · today")
  assert.equal(T.rowDetail(alarm({ days: [0, 6] }), at(1, 7, 30), NOW), "weekends · next Sat")
  assert.equal(T.rowDetail(alarm({ enabled: false, snoozedUntil: at(0, 14, 11) }), at(0, 14, 11), NOW), "once · snoozed to 14:11", "a snooze outranks off")
  assert.equal(T.rowDetail(alarm(), 0, NOW), "once · off", "an alarm with nothing left to ring reads off")
})

test("ringTitle is the label, the time when there is no label, and a count for several", () => {
  const byId = { 1: alarm(), 2: alarm({ id: 2, label: "", hour: 6, minute: 0 }), 3: alarm({ id: 3 }) }
  const ring = (ids) => ({ startedAt: NOW, events: ids.map((id) => ({ id, startedAt: NOW })) })
  assert.equal(T.ringTitle(ring([1]), byId), "Wake up")
  assert.equal(T.ringTitle(ring([2]), byId), "06:00")
  assert.equal(T.ringTitle(ring([1, 2, 3]), byId), "3 alarms")
  assert.equal(T.ringTitle(ring([99]), byId), "Alarm", "an event whose alarm is gone still has a title")
  assert.equal(T.ringTitle(null, byId), "")
})

test("snoozeLabel names the minutes when every ringing alarm agrees", () => {
  const byId = { 1: alarm(), 2: alarm({ id: 2, snoozeMinutes: 9 }), 3: alarm({ id: 3, snoozeMinutes: 15 }) }
  const ring = (ids) => ({ startedAt: NOW, events: ids.map((id) => ({ id, startedAt: NOW })) })
  assert.equal(T.snoozeLabel(ring([1]), byId), "Snooze 9 min")
  assert.equal(T.snoozeLabel(ring([1, 2]), byId), "Snooze 9 min")
  assert.equal(T.snoozeLabel(ring([1, 3]), byId), "Snooze")
  assert.equal(T.snoozeLabel(null, byId), "Snooze")
})

test("lateText is how late, in the largest two units", () => {
  assert.equal(T.lateText(14 * MIN), "14 min late")
  assert.equal(T.lateText(132 * MIN), "2 h 12 min late")
  assert.equal(T.lateText(26 * 60 * MIN), "1 d 2 h late")
  assert.equal(T.lateText(30 * 1000), "0 min late")
})

test("missedText is one notification for every missed alarm", () => {
  const byId = { 1: alarm(), 2: alarm({ id: 2, label: "", hour: 6, minute: 10 }) }
  const one = T.missedText([{ id: 1, at: at(0, 11, 48), kind: "scheduled" }], byId, NOW)
  assert.deepEqual(one, { headline: "Missed alarm", body: "07:30 · Wake up, 2 h 12 min late" })
  const two = T.missedText([{ id: 2, at: at(0, 6, 10), kind: "scheduled" }, { id: 1, at: at(0, 7, 30), kind: "scheduled" }], byId, NOW)
  assert.deepEqual(two, { headline: "2 missed alarms", body: "06:10, 7 h 50 min late\n07:30 · Wake up, 6 h 30 min late" })
  assert.equal(T.missedText([], byId, NOW), null)
})

test("ringView is what the card and the chip show, with the meter as the first event's elapsed share", () => {
  const byId = { 1: alarm({ days: [0, 6] }), 2: alarm({ id: 2, label: "Pills", hour: 6, minute: 0, ringMinutes: 1 }) }
  const ring = { startedAt: NOW, events: [{ id: 1, startedAt: NOW }, { id: 2, startedAt: NOW + 30 * 1000 }] }
  const one = T.ringView({ startedAt: NOW, events: [ring.events[0]] }, byId, NOW + 42 * 1000)
  assert.deepEqual(one, { clock: "07:30", title: "Wake up", subtitle: "Alarm · weekends", snoozeLabel: "Snooze 9 min", progress: 42 / 300 })
  const both = T.ringView(ring, byId, NOW + 60 * 1000)
  assert.equal(both.title, "2 alarms")
  assert.equal(both.subtitle, "07:30 · 06:00")
  assert.equal(both.clock, "07:30")
  assert.equal(T.ringView(ring, byId, NOW + 3600 * 1000).progress, 1)
  assert.equal(T.ringView(null, byId, NOW), null)
})
