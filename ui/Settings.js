.pragma library

// Every Settings string. No QML imports, so Node tests it (ADR-0009). The
// sound catalog and its names live in data/Sound.js.

// The Settings sections, in the order of the list.
var SECTIONS = [
  { id: "sound", label: "Alarm sound" },
  { id: "alarms", label: "Alarms" },
  { id: "updates", label: "Updates" },
  { id: "history", label: "History" },
  { id: "data", label: "Data" }
]

// The steppers' captions, with the range `spec` (Db.SETTINGS) accepts.
function rangeText(entry) {
  return entry ? " " + entry.min + " to " + entry.max + " min." : ""
}

function snoozeCaption(spec) {
  return "Length of Snooze on the ring card." + rangeText(spec ? spec.snoozeMinutes : null)
}

function ringCaption(spec) {
  return "Rings this long, then snoozes by itself." + rangeText(spec ? spec.ringMinutes : null)
}

var KEEP_CHOICES = [
  { value: 0, label: "Forever" },
  { value: 90, label: "90 days" },
  { value: 30, label: "30 days" }
]

// The History row's meta: "forever" or "30d".
function keepText(days) {
  return days > 0 ? days + "d" : "forever"
}

// "900 B", "212 KB", "5.3 MB".
function sizeText(bytes) {
  var b = Number(bytes) || 0
  if (b < 1024) return b + " B"
  if (b < 1024 * 1024) return Math.round(b / 1024) + " KB"
  return (b / (1024 * 1024)).toFixed(1) + " MB"
}

// `path` with the home directory written as ~.
function pathText(path, home) {
  var p = String(path || "")
  var h = String(home || "")
  return h !== "" && (p === h || p.indexOf(h + "/") === 0) ? "~" + p.slice(h.length) : p
}

// What a section row shows on its right, from the same settings the page
// edits: "Bell" or "off", "9 / 5 min". `info` carries what is not a
// setting: { sound, bytes }, `sound` being the name of the sound the ring
// plays.
function sectionMeta(id, settings, info) {
  if (!settings) return ""
  if (id === "sound") return settings.soundOn ? (info ? info.sound : "") : "off"
  if (id === "alarms") return settings.snoozeMinutes + " / " + settings.ringMinutes + " min"
  if (id === "history") return keepText(settings.historyDays)
  if (id === "data") return sizeText(info ? info.bytes : 0)
  if (id === "updates") return VERSION
  return ""
}

// The version of this code. It ships with the code, so after an update and
// before the restart the page still names the version that runs;
// test/settings-text.test.mjs holds it to manifest.json.
var VERSION = "1.2.0"

// The plugin updates through Omarchy, not by itself (ADR-0021). The page
// shows both commands and copies only the update: `omarchy plugin update`
// exits 0 also when there is nothing new or the user says no, so a restart
// chained to it would drop a ringing alarm for nothing.
var PLUGIN_ID = "othavi0.omanotes"
var UPDATE_COMMAND = "omarchy plugin update " + PLUGIN_ID
var RESTART_COMMAND = "omarchy restart shell"
var UPDATE_COMMANDS = [UPDATE_COMMAND, RESTART_COMMAND]
var UPDATED_LINE = "Updated " + PLUGIN_ID + "."

var UPDATE_CAPTION = "Copy the update and run it in a terminal. Omarchy shows the changes and asks before it pulls."
var RESTART_NOTE = "Run " + RESTART_COMMAND + " only after the update prints \u201c" + UPDATED_LINE + "\u201d The restart loads the new version and stops a ringing alarm."
var COPIED_TEXT = "Copied. Paste it in a terminal."

// The toast of a copy that failed: wl-copy's first line of error, or its
// exit code when it said nothing, or that it never started.
function copyFailedText(exitCode, stderr, program) {
  var line = String(stderr || "").trim().split("\n")[0]
  if (exitCode === null || exitCode === undefined) return "Not copied: " + program + " did not start"
  return "Not copied: " + (line !== "" ? line : program + " exited with " + exitCode)
}
