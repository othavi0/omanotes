.pragma library

// The pure half of the data layer: what a request to bin/omanotes-db carries,
// what its answer means, what the raw cells of a snapshot become, what the
// views lay over them, and the words a failure shows. The SQL lives in the
// binary (ADR-0018). No QML imports, so Node loads this file (ADR-0009).

// The protocol this QML speaks, argv[1] of every spawn. The binary answers
// every protocol from its Min to its Current (db/Wire.cs). test/lib/harness.sh
// reads this line, so it stays a plain number assigned to PROTOCOL on one
// line.
var PROTOCOL = 2

// A request over this many bytes is refused by the binary as too_large, so
// the Store never sends one.
var MAX_REQUEST_BYTES = 1048576

// The largest write the Store queues. The rest of a request is kept for the
// sync, whose searches MAX_QUERY bounds (twelve views with the longest search
// fit), and for the envelope. A bigger write is refused at once, so the
// editor gets its text back before anything is sent.
var MAX_WRITE_BYTES = MAX_REQUEST_BYTES - 16384 - 64

// A search goes out cut to this many UTF-16 units. Folded, the longest unit
// takes 6 bytes, so a search stays far under the 50 000 bytes SQLite takes
// in a LIKE pattern.
var MAX_QUERY = 200

// The search of a view as the Store sends it and as the view compares the
// answer: trimmed as the binary expects, then cut.
function viewQuery(text) {
  return String(text || "").trim().slice(0, MAX_QUERY)
}

// Unix timestamp in seconds: the `at` of every write. The binary has no clock.
function now() {
  return Math.floor(Date.now() / 1000)
}

// An id the wire takes: anything but a whole number is refused before a
// spawn, with the words the IPC has always answered.
function wholeId(id) {
  if (!/^\d+$/.test(String(id))) throw new Error("invalid id: " + id)
  return Number(id)
}

// A whole number in [min, max], refused otherwise.
function wholeIn(value, min, max) {
  var n = Number(value)
  if (typeof value === "boolean" || !/^-?\d+$/.test(String(value)) || n < min || n > max) {
    throw new Error("invalid value: " + value)
  }
  return n
}

// A list of Date.getDay() indices <-> the days bitmask, bit 0 for Sunday.
function daysMask(days) {
  var mask = 0
  var list = days || []
  for (var i = 0; i < list.length; i++) {
    var d = Number(list[i])
    if (d >= 0 && d <= 6 && d === Math.round(d)) mask |= 1 << d
  }
  return mask
}

function maskDays(mask) {
  var days = []
  for (var d = 0; d <= 6; d++) if ((Number(mask) >> d) & 1) days.push(d)
  return days
}

// An Alarm record as the cells of its row, every writable column, checked
// before a spawn. The binary writes the record whole (ADR-0015), and the
// CHECK constraints refuse the same ranges again.
function alarmCells(record) {
  var ms = Number.MAX_SAFE_INTEGER
  return {
    hour: wholeIn(record.hour, 0, 23),
    minute: wholeIn(record.minute, 0, 59),
    label: String(record.label || ""),
    days: daysMask(record.days),
    enabled: record.enabled ? 1 : 0,
    snooze_minutes: wholeIn(record.snoozeMinutes, 1, 180),
    ring_minutes: wholeIn(record.ringMinutes, 1, 60),
    snoozed_until_ms: wholeIn(record.snoozedUntil, 0, ms),
    last_fired_at_ms: wholeIn(record.lastFiredAt, 0, ms),
    armed_at_ms: wholeIn(record.armedAt, 0, ms),
    auto_snoozes: wholeIn(record.autoSnoozes, 0, 99)
  }
}

function clampedInt(value, min, max, fallback) {
  var n = Math.round(Number(value))
  if (value === null || value === "" || !isFinite(n)) return fallback
  return Math.max(min, Math.min(max, n))
}

// The alarm rows of a snapshot -> Alarm records: numbers, a days list and a
// boolean, with camelCase names. SQLite keeps a fraction written to an
// INTEGER column as REAL, so a hand edit can leave 6.4 in `hour`, and the
// binary sends an infinite REAL as 9e999, which reads as Infinity here.
function parseAlarms(rows) {
  var ms = Number.MAX_SAFE_INTEGER
  return (rows || []).map(function(row) {
    return {
      id: Number(row.id),
      hour: clampedInt(row.hour, 0, 23, null),
      minute: clampedInt(row.minute, 0, 59, null),
      label: String(row.label || ""),
      days: maskDays(row.days),
      enabled: Number(row.enabled) === 1,
      snoozeMinutes: clampedInt(row.snooze_minutes, 1, 180, 9),
      ringMinutes: clampedInt(row.ring_minutes, 1, 60, 5),
      snoozedUntil: clampedInt(row.snoozed_until_ms, 0, ms, 0),
      lastFiredAt: clampedInt(row.last_fired_at_ms, 0, ms, 0),
      armedAt: clampedInt(row.armed_at_ms, 0, ms, 0),
      autoSnoozes: clampedInt(row.auto_snoozes, 0, 99, 0)
    }
  }).filter(function(alarm) {
    return alarm.id > 0 && alarm.hour !== null && alarm.minute !== null
  })
}

// The rows with each pending record laid over its row. A pending null drops
// the row, and a pending record whose row is gone is not brought back. The
// order is the snapshot's order.
function mergeAlarms(rows, pending) {
  var out = []
  for (var i = 0; i < rows.length; i++) {
    var entry = pending ? pending[rows[i].id] : undefined
    if (entry === undefined) out.push(rows[i])
    else if (entry.record !== null) out.push(entry.record)
  }
  return out
}

// The settings record, { soundOn, sound, soundFile, volume, snoozeMinutes,
// ringMinutes, historyDays }, one spec per key. It drives the read, the write
// and the fallbacks, and the binary only checks each column name against the
// schema (ADR-0016). The schema still has check_updates, which nothing reads
// since the plugin stopped updating itself (ADR-0021). The sound catalog lives in
// data/Sound.js and is not checked here, so a new sound needs no migration.
// The sound fallback repeats Sound.DEFAULT_SOUND, which this file cannot
// import under Node; test/sound.test.mjs holds them equal.
var SETTINGS = {
  soundOn: { column: "sound_on", kind: "bool", fallback: true },
  sound: { column: "sound", kind: "text", fallback: "alarm-clock-elapsed" },
  soundFile: { column: "sound_file", kind: "text", fallback: "" },
  volume: { column: "volume", kind: "int", min: 0, max: 100, fallback: 100 },
  snoozeMinutes: { column: "snooze_minutes", kind: "int", min: 1, max: 180, fallback: 9 },
  ringMinutes: { column: "ring_minutes", kind: "int", min: 1, max: 60, fallback: 5 },
  historyDays: { column: "history_days", kind: "pick", options: [0, 90, 30], fallback: 0 }
}

function settingValue(key, value) {
  var spec = SETTINGS[key]
  if (!spec) throw new Error("unknown setting: " + key)
  var ok = spec.kind === "bool" ? typeof value === "boolean"
    : spec.kind === "text" ? typeof value === "string"
    : spec.kind === "pick" ? spec.options.indexOf(value) >= 0
    : typeof value === "number" && value === Math.round(value) && value >= spec.min && value <= spec.max
  if (!ok) throw new Error("invalid setting: " + key + " " + JSON.stringify(value))
  return spec.kind === "bool" ? (value ? 1 : 0) : value
}

// The cells of a settings patch, keyed by column. Throws on an unknown key
// or a value outside its spec: the controls clamp, this refuses. The binary
// writes only these columns, so two panels writing different keys never undo
// each other, and a shorter Keep prunes in the same transaction.
function settingsCells(patch) {
  var keys = Object.keys(patch || {})
  if (keys.length === 0) throw new Error("empty setting patch")
  var cells = {}
  for (var i = 0; i < keys.length; i++) {
    var value = settingValue(keys[i], patch[keys[i]])
    cells[SETTINGS[keys[i]].column] = value
  }
  return cells
}

// The settings row of a snapshot, with the file size -> { settings, bytes }.
// A value a hand edit left out of range is clamped or falls back, so a read
// never fails on it. A row deleted by hand reads as NULL cells, and null
// gives every fallback.
function parseSettings(row) {
  var cells = row || {}
  var settings = {}
  for (var key in SETTINGS) {
    var spec = SETTINGS[key]
    var v = cells[spec.column]
    if (v === null || v === undefined) settings[key] = spec.fallback
    else if (spec.kind === "bool") settings[key] = Number(v) === 0 ? false : Number(v) === 1 ? true : spec.fallback
    else if (spec.kind === "text") settings[key] = String(v)
    else if (spec.kind === "pick") settings[key] = spec.options.indexOf(Number(v)) >= 0 ? Number(v) : spec.fallback
    else settings[key] = clampedInt(v, spec.min, spec.max, spec.fallback)
  }
  return { settings: settings, bytes: Number(cells.db_bytes) || 0 }
}

function mergeSettings(settings, patch) {
  var out = {}
  for (var key in settings) out[key] = settings[key]
  for (var k in patch) out[k] = patch[k]
  return out
}

// The counts row of a snapshot -> { unreadNotes, pendingTodos, notes, todos,
// history, oldestHistory }. `oldest` is the time of the oldest history
// entry, 0 with none.
function parseCounts(row) {
  var cells = row || {}
  return {
    unreadNotes: Number(cells.unreadNotes) || 0,
    pendingTodos: Number(cells.pendingTodos) || 0,
    notes: Number(cells.notes) || 0,
    todos: Number(cells.todos) || 0,
    history: Number(cells.history) || 0,
    oldestHistory: Number(cells.oldest) || 0
  }
}

// True when keeping `days` of history would remove an entry, from the
// oldest entry's time (seconds, 0 with none) and now (seconds).
function prunes(days, oldest, nowSeconds) {
  return days > 0 && oldest > 0 && oldest < nowSeconds - days * 86400
}

// `rows` with the row `id` moved as item.move moves it, so the list shows the
// drop before the write confirms it. The same rows when either is missing.
function movedRows(rows, id, anchorId, after) {
  var list = rows.slice()
  var from = -1
  for (var i = 0; i < list.length; ++i) if (Number(list[i].id) === Number(id)) from = i
  if (from < 0) return list
  var row = list.splice(from, 1)[0]
  for (var j = 0; j < list.length; ++j) {
    if (Number(list[j].id) !== Number(anchorId)) continue
    list.splice(after ? j + 1 : j, 0, row)
    return list
  }
  return rows.slice()
}

// The rows a view shows: every item narrowed by type, in the snapshot's
// order. A search is answered by the binary, whose ids come in the same
// order (the fold table lives there, ADR-0012).
function typeRows(allItems, filter) {
  if (filter !== "note" && filter !== "todo") return allItems
  return allItems.filter(function(item) { return item.type === filter })
}

function matchedRows(itemsById, ids) {
  var out = []
  for (var i = 0; i < ids.length; ++i) if (itemsById[ids[i]]) out.push(itemsById[ids[i]])
  return out
}

var ROW_FIELDS = ["id", "type", "title", "body", "status", "created_at", "updated_at"]

// Whether two lists show the same rows in the same order, field by field. A
// snapshot that changes nothing a list shows, such as the echo the watcher
// asks for after a write, then rebuilds nothing and cancels no drag.
function sameRows(a, b) {
  if (a.length !== b.length) return false
  for (var i = 0; i < a.length; ++i) {
    if (a[i] === b[i]) continue
    for (var f = 0; f < ROW_FIELDS.length; ++f) {
      if (a[i][ROW_FIELDS[f]] !== b[i][ROW_FIELDS[f]]) return false
    }
  }
  return true
}

// The failures a retry would get again: the record, the side or the size is
// wrong, not the moment.
function definitive(err) {
  return err === "bad_request" || err === "forbidden" || err === "too_large" || err === "refused"
}

// Whether the Store asks again, with back-off, for a read that failed. A
// snapshot over 64 MiB fails only after the binary wrote 64 MiB, which the
// shell collects, so each retry would cost that again.
function retriesRead(err) {
  return err !== "response_too_large"
}

// The text with every lone surrogate replaced by U+FFFD. The QML engine
// sends a lone surrogate raw on stdin, where the decoder drops it, and the
// binary refuses an escaped one; the argv of the sqlite3 CLI turned it into
// U+FFFD, and so does this.
function wellFormed(s) {
  return s.replace(/[\ud800-\udbff][\udc00-\udfff]|[\ud800-\udfff]/g,
    function(m) { return m.length === 2 ? m : "�" })
}

function wellFormedStrings(key, value) {
  return typeof value === "string" ? wellFormed(value) : value
}

// One write as it travels on stdin, { id, by, op, at, args }, serialized once
// when it is queued: the Store measures it and sends it as it is.
function writeJson(write) {
  return JSON.stringify(write, wellFormedStrings)
}

// The stdin of one spawn: the writes in order, each from writeJson, then a
// sync that asks for the snapshot after them ({ since, views }).
function request(writeJsons, sync) {
  var members = []
  if (writeJsons.length > 0) members.push("\"writes\":[" + writeJsons.join(",") + "]")
  if (sync) members.push("\"sync\":" + JSON.stringify(sync, wellFormedStrings))
  return "{" + members.join(",") + "}"
}

// The bytes `text` takes in UTF-8, counted unit by unit with no copy. A lone
// surrogate counts as the U+FFFD that wellFormed puts in its place.
function utf8Length(text) {
  var bytes = 0
  for (var i = 0; i < text.length; ++i) {
    var c = text.charCodeAt(i)
    if (c < 0x80) bytes += 1
    else if (c < 0x800) bytes += 2
    else if (c >= 0xd800 && c <= 0xdbff && (text.charCodeAt(i + 1) & 0xfc00) === 0xdc00) {
      bytes += 4
      ++i
    } else bytes += 3
  }
  return bytes
}

// argv of a request. No user text travels here: an argument over 128 KiB
// kept the process from starting, and the note was lost (issue #55).
function command(binary, dbPath) {
  return [String(binary), String(PROTOCOL), "run", String(dbPath)]
}

function parsedJson(text) {
  try {
    return JSON.parse(text)
  } catch (e) {
    return null
  }
}

function parsedObject(text) {
  var value = parsedJson(text)
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value : null
}

// What a finished spawn of a request with `writes` writes answered:
// { ok: true, results, snapshot, syncErr, log } or { ok: false, err, detail,
// log }. Protocol 2 writes one line per write, in order, each as soon as its
// write ends, then the snapshot (ADR-0020). Only a line ended by "\n" is
// whole. Each whole result line stands even when the process failed or was
// killed after it, so a write that committed is never told it failed; the
// writes with no line are the Store's `crash`, and syncErr is the failure.
// Exit 3: the snapshot failed, {"syncErr"} on the last line of stderr. Exit
// 1, 64 or 70: the last line of stderr names the failure. Any other exit, a
// signal or a snapshot that does not parse is a crash. `log` is every other
// line of stderr, such as a migration the binary ran.
function reply(writes, exitCode, crashed, stdoutText, stderrText) {
  var lines = String(stdoutText || "").split("\n")
  var tail = lines.pop()
  var results = []
  while (results.length < writes && results.length < lines.length) {
    var result = parsedObject(lines[results.length])
    if (!result || typeof result.id !== "number") break
    results.push(result)
  }
  var whole = results.length === writes
  var log = String(stderrText || "").split("\n").map(function(line) { return line.trim() })
    .filter(function(line) { return line !== "" })
  var last = crashed || log.length === 0 ? null : parsedJson(log[log.length - 1])
  var told = !last ? null
    : exitCode === 3 ? (whole ? last.syncErr : null)
    : exitCode === 1 || exitCode === 64 || exitCode === 70 ? last : null
  var clean = !crashed && exitCode === 0
  var failure = { err: "crash", detail: clean ? "unreadable answer" : crashed ? "signal " + exitCode : "exit " + exitCode }
  if (told && typeof told.err === "string") {
    failure = { err: told.err, detail: String(told.detail || "") }
    log.pop()
  }
  var syncErr = whole && clean ? null : failure
  var snapshot = null
  // A read always asks for the snapshot; a request with writes may not.
  if (!syncErr && (writes === 0 || lines.length > writes || tail !== "")) {
    snapshot = lines.length > writes ? parsedObject(lines[writes]) : null
    if (!snapshot) syncErr = failure
  }
  if (writes > 0 ? results.length === 0 : !snapshot && !(exitCode === 3 && !crashed)) {
    return { ok: false, err: failure.err, detail: failure.detail, log: log }
  }
  return { ok: true, results: results, snapshot: snapshot, syncErr: syncErr, log: log }
}

// The words a failure shows, in the toast and the journal. null keeps the
// words SQLite gave ("disk I/O error", "attempt to write a readonly
// database", a CHECK that failed), as the sqlite3 CLI printed them.
// "item not found" is compared by ui/ItemsTab.qml, word for word.
var ERROR_TEXT = {
  busy: "database is locked",
  not_found: "item not found",
  refused: null,
  io: null,
  corrupt: null,
  sqlite: null,
  sqlite_too_old: null,
  selftest: null,
  sqlite_missing: "libsqlite3 is not installed",
  forbidden: "not allowed from here",
  bad_request: "the database helper refused the request",
  timeout: "the database helper got no request",
  too_large: "text too large to save",
  response_too_large: "the notes are over 64 MiB, too large to read",
  protocol: "Omanotes was updated. Run omarchy restart shell to finish",
  internal: "the database helper failed",
  crash: "the database helper stopped without an answer",
  no_binary: "cannot run the database helper"
}

// `failure` is { err, detail }: a write's result, a request that failed or
// a sync that failed.
function errorText(failure) {
  var text = ERROR_TEXT[failure.err]
  if (text === null) return failure.detail || failure.err
  if (text === undefined) return "database error: " + failure.err
  if (failure.err === "no_binary") return text + " " + failure.detail
  return text
}
