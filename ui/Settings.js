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
// setting: { sound, bytes, version }, `sound` being the name of the sound
// the ring plays.
function sectionMeta(id, settings, info) {
  if (!settings) return ""
  if (id === "sound") return settings.soundOn ? (info ? info.sound : "") : "off"
  if (id === "alarms") return settings.snoozeMinutes + " / " + settings.ringMinutes + " min"
  if (id === "history") return keepText(settings.historyDays)
  if (id === "data") return sizeText(info ? info.bytes : 0)
  if (id === "updates") return (info && info.version) || ""
  return ""
}

// The plugin updates through Omarchy, not by itself (ADR-0021): the Updates
// page shows these commands and copies them as one line, joined by &&, so
// an update that fails does not restart the shell.
var PLUGIN_ID = "othavi0.omanotes"
var UPDATE_COMMANDS = ["omarchy plugin update " + PLUGIN_ID, "omarchy restart shell"]
var LISTING_URL = "https://omarchyplugins.com/plugin.html?id=" + PLUGIN_ID

function updateCommandLine() {
  return UPDATE_COMMANDS.join(" && ")
}

// The version of manifest.json's text, "" when it cannot be read.
function manifestVersion(text) {
  try {
    var version = JSON.parse(String(text)).version
    return typeof version === "string" ? version : ""
  } catch (e) {
    return ""
  }
}
