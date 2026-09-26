.pragma library

// Alarm scheduling, adapted from Chime (MIT, see NOTICE). Pure functions over
// plain alarm records; the caller owns the clock, the sound and the storage.
//
// An alarm is { id, hour, minute, label, days, enabled, snoozeMinutes,
// ringMinutes, snoozedUntil, lastFiredAt, armedAt, autoSnoozes }. Instants are
// epoch ms, 0 meaning none. days holds Date.getDay() indices (0 is Sunday); an
// empty list rings once. The record is a wall-clock time plus the instants
// already consumed, never a countdown, so the same functions answer "is it
// due?" after a restart or a night asleep.

// An occurrence this recent still rings; older ones are reported as missed
// instead of going off hours late.
var GRACE_MS = 10 * 60 * 1000
var MAX_AUTO_SNOOZES = 3
var DEFAULT_SNOOZE_MINUTES = 9
var DEFAULT_RING_MINUTES = 5
var MIN_SNOOZE_MINUTES = 1
var MAX_SNOOZE_MINUTES = 180
var MIN_RING_MINUTES = 1
var MAX_RING_MINUTES = 60
var MAX_ALARMS = 50
var MAX_LABEL = 40
var MINUTE_MS = 60 * 1000
// Offset 7 reaches today's weekday once its time has passed; Chime keeps one
// more day of margin.
var SEARCH_DAYS = 8

function normalizeDays(days) {
  var list = []
  var source = typeof days === "string" ? days.split(/[\s,]+/) : days
  if (!source || typeof source.length !== "number") return list
  for (var i = 0; i < source.length; i++) {
    // Number("") is 0, which would quietly turn "no days" into Sunday.
    if (source[i] === null || source[i] === undefined || String(source[i]).trim() === "") continue
    var n = Number(source[i])
    if (!isFinite(n) || Math.round(n) !== n || n < 0 || n > 6) continue
    if (list.indexOf(n) === -1) list.push(n)
  }
  list.sort(function(a, b) { return a - b })
  return list
}

function isRepeating(alarm) {
  return !!alarm && normalizeDays(alarm.days).length > 0
}

// Whether a reload shows that a ringing alarm was taken away outside: the
// row is gone, or a repeating alarm was switched off. A one-shot is switched
// off by its own ring, so `enabled` says nothing about it.
function lostOutside(alarm) {
  return !alarm || (!alarm.enabled && isRepeating(alarm))
}

function instant(value) {
  return Number(value) || 0
}

// Walks day offsets from the local day of `fromMs` in direction `step` and
// returns the first occurrence `accepts` takes, or 0. The local Date
// constructor puts a daylight-saving change where the wall clock says.
function walkOccurrences(alarm, fromMs, step, accepts) {
  var days = normalizeDays(alarm.days)
  var base = new Date(instant(fromMs))
  for (var offset = 0; Math.abs(offset) <= SEARCH_DAYS; offset += step) {
    var c = new Date(base.getFullYear(), base.getMonth(), base.getDate() + offset, alarm.hour, alarm.minute, 0, 0)
    if (!accepts(c.getTime())) continue
    if (days.length === 0 || days.indexOf(c.getDay()) !== -1) return c.getTime()
  }
  return 0
}

function occurrenceAfter(alarm, afterMs) {
  return walkOccurrences(alarm, afterMs, 1, function(t) { return t > afterMs })
}

function occurrenceAtOrBefore(alarm, beforeMs) {
  return walkOccurrences(alarm, beforeMs, -1, function(t) { return t <= beforeMs })
}

// When the alarm rings next, or 0. A future snooze outranks the schedule and
// `enabled`.
function alarmNextAt(alarm, nowMs) {
  if (!alarm) return 0
  if (instant(alarm.snoozedUntil) > nowMs) return instant(alarm.snoozedUntil)
  if (!alarm.enabled) return 0
  return occurrenceAfter(alarm, Math.max(nowMs, instant(alarm.lastFiredAt), instant(alarm.armedAt)))
}

// The occurrence this tick owes a ring for: { at, kind } or null. The floor
// leaves nowMs out on purpose: an occurrence already behind now is still owed
// until lastFiredAt consumes it, which is how a late tick finds a missed one.
function alarmDue(alarm, nowMs) {
  if (!alarm) return null
  var snoozed = instant(alarm.snoozedUntil)
  if (snoozed > 0 && snoozed <= nowMs) return { at: snoozed, kind: "snooze" }
  if (!alarm.enabled) return null
  var occ = occurrenceAtOrBefore(alarm, nowMs)
  if (occ <= 0) return null
  if (occ <= Math.max(instant(alarm.lastFiredAt), instant(alarm.armedAt))) return null
  return { at: occ, kind: "scheduled" }
}

// The soonest ring among all alarms: { alarm, at } or null.
function nextAlarm(alarms, nowMs) {
  var best = null
  var list = alarms || []
  for (var i = 0; i < list.length; i++) {
    var at = alarmNextAt(list[i], nowMs)
    if (at > 0 && (!best || at < best.at)) best = { alarm: list[i], at: at }
  }
  return best
}

// What collecting a due ring writes back, by kind.
var DUE_PATCH = {
  snooze: function() {
    return { snoozedUntil: 0 }
  },
  scheduled: function(alarm, due) {
    var patch = { snoozedUntil: 0, lastFiredAt: due.at, autoSnoozes: 0 }
    if (!isRepeating(alarm)) patch.enabled = false
    return patch
  }
}

// One clock tick over every alarm. Each due alarm is patched whether it rings
// or is missed, so a one-shot found hours late is still consumed and disabled.
function tick(alarms, nowMs) {
  return (alarms || []).reduce(function(acc, alarm) {
    var due = alarmDue(alarm, nowMs)
    if (!due) return acc
    acc.patches.push({ id: alarm.id, patch: DUE_PATCH[due.kind](alarm, due) })
    var bucket = nowMs - due.at <= GRACE_MS ? acc.ring : acc.missed
    bucket.push({ id: alarm.id, at: due.at, kind: due.kind })
    return acc
  }, { patches: [], ring: [], missed: [] })
}

function clampMinutes(minutes, min, max, fallback) {
  var n = Number(minutes)
  if (minutes === undefined || minutes === null || minutes === "" || !isFinite(n)) return fallback
  return Math.max(min, Math.min(max, Math.round(n)))
}

function snoozeMinutes(minutes) {
  return clampMinutes(minutes, MIN_SNOOZE_MINUTES, MAX_SNOOZE_MINUTES, DEFAULT_SNOOZE_MINUTES)
}

function ringMinutes(minutes) {
  return clampMinutes(minutes, MIN_RING_MINUTES, MAX_RING_MINUTES, DEFAULT_RING_MINUTES)
}

// "07:30", "0730" or "7:30" -> { hour, minute }, or null.
function parseTime(text) {
  var m = /^(\d{1,2}):?(\d{2})$/.exec(String(text === null || text === undefined ? "" : text).trim())
  if (!m) return null
  var hour = Number(m[1])
  var minute = Number(m[2])
  if (hour > 23 || minute > 59) return null
  return { hour: hour, minute: minute }
}

// Editor input { time, label, days, snoozeMinutes, ringMinutes } -> the
// fields of an alarm, or null when the time does not parse. Minutes are
// clamped, and the label is trimmed, its control characters turned into
// spaces, and capped at MAX_LABEL.
function parseFields(input) {
  var time = parseTime(input ? input.time : "")
  if (!time) return null
  var label = String(input.label === undefined || input.label === null ? "" : input.label)
    .replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, MAX_LABEL)
  return {
    hour: time.hour,
    minute: time.minute,
    label: label,
    days: normalizeDays(input.days),
    snoozeMinutes: snoozeMinutes(input.snoozeMinutes),
    ringMinutes: ringMinutes(input.ringMinutes)
  }
}

function newAlarm(fields, nowMs) {
  return {
    hour: fields.hour, minute: fields.minute, label: fields.label, days: fields.days, enabled: true,
    snoozeMinutes: fields.snoozeMinutes, ringMinutes: fields.ringMinutes,
    snoozedUntil: 0, lastFiredAt: 0, armedAt: nowMs, autoSnoozes: 0
  }
}

// What an edit writes. A change of hour, minute or days re-arms the alarm
// (Chime's updateAlarm): armed now, no snooze, switched on, count reset. A
// label or minutes change leaves all of that alone.
function editPatch(alarm, fields, nowMs) {
  var patch = {
    hour: fields.hour, minute: fields.minute, label: fields.label, days: normalizeDays(fields.days),
    snoozeMinutes: fields.snoozeMinutes, ringMinutes: fields.ringMinutes
  }
  var rearm = patch.hour !== Number(alarm.hour) || patch.minute !== Number(alarm.minute)
    || patch.days.join(",") !== normalizeDays(alarm.days).join(",")
  if (rearm) {
    patch.armedAt = nowMs
    patch.snoozedUntil = 0
    patch.enabled = true
    patch.autoSnoozes = 0
  }
  return patch
}

// What the row switch writes. On: armed now, no snooze, count reset. Off:
// no snooze either, which also cancels the snooze of a disabled one-shot.
function enablePatch(alarm, on, nowMs) {
  return on ? { enabled: true, armedAt: nowMs, snoozedUntil: 0, autoSnoozes: 0 } : { enabled: false, snoozedUntil: 0 }
}

// What the row switch shows: enabled, or snoozed into the future.
function isOn(alarm, nowMs) {
  return !!alarm && (!!alarm.enabled || instant(alarm.snoozedUntil) > nowMs)
}

function withPatch(alarm, patch) {
  var out = {}
  for (var k in alarm) out[k] = alarm[k]
  for (var p in patch) out[p] = patch[p]
  return out
}

// Ring-state transitions. The card is { startedAt, events: [{ id, startedAt }] }
// or null. An id already on the card is ignored, a new event starts at
// nowMs, and the card keeps the startedAt of its first event.
function ringWith(ring, ids, nowMs) {
  var events = ring ? ring.events.slice() : []
  for (var i = 0; i < ids.length; i++) {
    var known = events.some(function(e) { return e.id === ids[i] })
    if (!known) events.push({ id: ids[i], startedAt: nowMs })
  }
  if (events.length === 0) return null
  return { startedAt: ring ? ring.startedAt : nowMs, events: events }
}

function ringWithout(ring, id) {
  if (!ring) return null
  var events = ring.events.filter(function(e) { return e.id !== id })
  if (events.length === ring.events.length) return ring
  if (events.length === 0) return null
  return { startedAt: ring.startedAt, events: events }
}

// A manual snooze is the person answering, so it restarts the automatic count.
function snoozePatch(alarm, minutes, automatic, nowMs) {
  return {
    snoozedUntil: nowMs + snoozeMinutes(minutes) * MINUTE_MS,
    autoSnoozes: automatic ? (Number(alarm.autoSnoozes) || 0) + 1 : 0
  }
}

// Splits ring events ({ id, startedAt }) into those still ringing and the ids
// of expired alarms that earn an automatic snooze.
function expire(events, alarmsById, nowMs) {
  return (events || []).reduce(function(acc, event) {
    var alarm = alarmsById ? alarmsById[event.id] : null
    var limit = alarm ? ringMinutes(alarm.ringMinutes) * MINUTE_MS : 0
    if (nowMs - instant(event.startedAt) < limit) {
      acc.keep.push(event)
      return acc
    }
    if (alarm && (Number(alarm.autoSnoozes) || 0) < MAX_AUTO_SNOOZES) acc.snooze.push(event.id)
    return acc
  }, { keep: [], snooze: [] })
}
