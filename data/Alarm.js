.pragma library

// Alarm scheduling, adapted from Chime (MIT, see NOTICE). Pure functions over
// plain alarm records; the caller owns the clock, the sound and the storage.
//
// An alarm is { id, hour, minute, days, enabled, snoozedUntil, lastFiredAt,
// armedAt, autoSnoozes }. Instants are epoch ms, 0 meaning none. days holds
// Date.getDay() indices (0 is Sunday); an empty list rings once. The record is
// a wall-clock time plus the instants already consumed, never a countdown, so
// the same functions answer "is it due?" after a restart or a night asleep.

// An occurrence this recent still rings; older ones are reported as missed
// instead of going off hours late.
var GRACE_MS = 10 * 60 * 1000
var MAX_AUTO_SNOOZES = 3
var DEFAULT_SNOOZE_MINUTES = 9
var DEFAULT_RING_SECONDS = 300
var MIN_SNOOZE_MINUTES = 1
var MAX_SNOOZE_MINUTES = 180
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

function snoozeMinutes(minutes) {
  var n = Number(minutes)
  if (!isFinite(n) || n < MIN_SNOOZE_MINUTES || n > MAX_SNOOZE_MINUTES) return DEFAULT_SNOOZE_MINUTES
  return Math.round(n)
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
function expire(events, alarmsById, nowMs, ringSeconds) {
  var limit = (Number(ringSeconds) > 0 ? Number(ringSeconds) : DEFAULT_RING_SECONDS) * 1000
  return (events || []).reduce(function(acc, event) {
    if (nowMs - instant(event.startedAt) < limit) {
      acc.keep.push(event)
      return acc
    }
    var alarm = alarmsById ? alarmsById[event.id] : null
    if (alarm && (Number(alarm.autoSnoozes) || 0) < MAX_AUTO_SNOOZES) acc.snooze.push(event.id)
    return acc
  }, { keep: [], snooze: [] })
}
