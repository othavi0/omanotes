.pragma library

// Every string the alarm views show, built from alarm records and instants
// in epoch ms. Free of QML imports so Node tests it (ADR-0009).

// The Repeat chips, Monday first. The letters follow this order; days
// themselves stay Date.getDay() indices (0 is Sunday).
var WEEK_ORDER = [1, 2, 3, 4, 5, 6, 0]
var DAY_LETTERS = ["M", "T", "W", "T", "F", "S", "S"]
var DAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var MINUTE_MS = 60 * 1000
var HOUR_MS = 60 * MINUTE_MS
var DAY_MS = 24 * HOUR_MS

function pad(n) {
  return (n < 10 ? "0" : "") + n
}

function timeText(hour, minute) {
  return pad(Number(hour)) + ":" + pad(Number(minute))
}

function clockOf(alarm) {
  return alarm ? timeText(alarm.hour, alarm.minute) : ""
}

function dayName(day) {
  return DAY_NAMES[Number(day)] || ""
}

function daysText(days) {
  var list = (days || []).map(Number)
  if (list.length === 0) return "once"
  if (list.length === 7) return "every day"
  var key = list.slice().sort().join(",")
  if (key === "1,2,3,4,5") return "weekdays"
  if (key === "0,6") return "weekends"
  return WEEK_ORDER.filter(function(d) { return list.indexOf(d) >= 0 }).map(dayName).join(", ")
}

function sameLocalDay(a, b) {
  var da = new Date(a)
  var db = new Date(b)
  return da.getFullYear() === db.getFullYear() && da.getMonth() === db.getMonth() && da.getDate() === db.getDate()
}

// "07:30" on the same local day, "Sat 07:30" on another, "" for 0.
function nextText(at, nowMs) {
  if (!(at > 0)) return ""
  var d = new Date(at)
  var clock = timeText(d.getHours(), d.getMinutes())
  return sameLocalDay(at, nowMs) ? clock : dayName(d.getDay()) + " " + clock
}

// A span in its largest two units: "1 d 17 h", "2 h 12 min", "14 min".
function spanText(ms) {
  var minutes = Math.floor(Math.max(0, ms) / MINUTE_MS)
  var days = Math.floor(minutes / (24 * 60))
  var hours = Math.floor(minutes / 60) % 24
  if (days > 0) return days + " d " + hours + " h"
  if (hours > 0) return hours + " h " + (minutes % 60) + " min"
  return minutes + " min"
}

// "next Sat, in 1 d 17 h", "today, in 42 min", "" for 0.
function nextInText(at, nowMs) {
  if (!(at > 0)) return ""
  var when = sameLocalDay(at, nowMs) ? "today" : "next " + dayName(new Date(at).getDay())
  return when + ", in " + spanText(at - nowMs)
}

function nextSummary(at, nowMs) {
  return at > 0 ? "next alarm " + nextText(at, nowMs) : "no alarm set"
}

// The days, then the state that matters most: a snooze ahead, off, or when
// the next ring lands.
function rowDetail(alarm, nowMs) {
  var days = daysText(alarm.days)
  var snoozed = Number(alarm.snoozedUntil) || 0
  if (snoozed > nowMs) {
    var s = new Date(snoozed)
    return days + " · snoozed to " + timeText(s.getHours(), s.getMinutes())
  }
  if (!alarm.enabled) return days + " · off"
  var next = nextOccurrence(alarm, nowMs)
  return days + " · " + (sameLocalDay(next, nowMs) ? "today" : "next " + dayName(new Date(next).getDay()))
}

// The next wall-clock occurrence after nowMs, walking a week ahead, for the
// row detail alone. The scheduling maths stays in data/Alarm.js.
function nextOccurrence(alarm, nowMs) {
  var list = (alarm.days || []).map(Number)
  var base = new Date(nowMs)
  for (var offset = 0; offset <= 7; offset++) {
    var c = new Date(base.getFullYear(), base.getMonth(), base.getDate() + offset, alarm.hour, alarm.minute, 0, 0)
    if (c.getTime() <= nowMs) continue
    if (list.length === 0 || list.indexOf(c.getDay()) >= 0) return c.getTime()
  }
  return nowMs
}

function eventsOf(ring) {
  return ring && ring.events ? ring.events : []
}

function alarmOf(alarmsById, id) {
  return alarmsById ? alarmsById[id] || null : null
}

// One event: its label, or its time without a label. Several: a count.
function ringTitle(ring, alarmsById) {
  var events = eventsOf(ring)
  if (events.length === 0) return ""
  if (events.length > 1) return events.length + " alarms"
  var alarm = alarmOf(alarmsById, events[0].id)
  if (!alarm) return "Alarm"
  return alarm.label !== "" ? alarm.label : clockOf(alarm)
}

// "Snooze 9 min" when every ringing alarm snoozes for the same length.
function snoozeLabel(ring, alarmsById) {
  var minutes = null
  var events = eventsOf(ring)
  for (var i = 0; i < events.length; i++) {
    var alarm = alarmOf(alarmsById, events[i].id)
    if (!alarm) continue
    if (minutes === null) minutes = Number(alarm.snoozeMinutes)
    else if (minutes !== Number(alarm.snoozeMinutes)) return "Snooze"
  }
  return minutes === null ? "Snooze" : "Snooze " + minutes + " min"
}

function lateText(ms) {
  return spanText(ms) + " late"
}

// The one notification for every alarm a tick found too late to ring.
function missedText(missed, alarmsById, nowMs) {
  if (!missed || missed.length === 0) return null
  var lines = missed.map(function(event) {
    var alarm = alarmOf(alarmsById, event.id)
    var d = new Date(event.at)
    var line = alarm ? clockOf(alarm) : timeText(d.getHours(), d.getMinutes())
    if (alarm && alarm.label !== "") line += " · " + alarm.label
    return line + ", " + lateText(nowMs - event.at)
  })
  return {
    headline: missed.length === 1 ? "Missed alarm" : missed.length + " missed alarms",
    body: lines.join("\n")
  }
}

// What the card and the chip show, or null when nothing rings. The meter is
// the first event's elapsed share of its alarm's ring length.
function ringView(ring, alarmsById, nowMs) {
  var events = eventsOf(ring)
  if (events.length === 0) return null
  var first = alarmOf(alarmsById, events[0].id)
  var subtitle = events.length === 1
    ? "Alarm · " + daysText(first ? first.days : [])
    : events.map(function(e) { return clockOf(alarmOf(alarmsById, e.id)) }).join(" · ")
  var length = (first && Number(first.ringMinutes) > 0 ? Number(first.ringMinutes) : 5) * MINUTE_MS
  return {
    clock: clockOf(first),
    title: ringTitle(ring, alarmsById),
    subtitle: subtitle,
    snoozeLabel: snoozeLabel(ring, alarmsById),
    progress: Math.max(0, Math.min(1, (nowMs - events[0].startedAt) / length))
  }
}
