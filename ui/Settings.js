.pragma library

// The sound catalog and every Settings string. No QML imports, so Node tests
// it (ADR-0009). The Service imports it for the ring's file, the tab for its
// wording.

var SOUND_DIR = "/usr/share/sounds/freedesktop/stereo/"
var DEFAULT_SOUND = "alarm-clock-elapsed"
var CUSTOM = "custom"
var SOUNDS = [
  { key: "alarm-clock-elapsed", name: "Alarm clock", length: "6.1 s" },
  { key: "service-login", name: "Chime", length: "2.2 s" },
  { key: "complete", name: "Complete", length: "1.1 s" },
  { key: "message-new-instant", name: "Message", length: "1.0 s" },
  { key: "window-attention", name: "Attention", length: "0.5 s" },
  { key: "bell", name: "Bell", length: "0.1 s" }
]

function catalogEntry(key) {
  for (var i = 0; i < SOUNDS.length; ++i) if (SOUNDS[i].key === key) return SOUNDS[i]
  return null
}

// The file a sound key plays. A custom key plays the chosen file, and a key
// the catalog does not know (a hand edit, a sound removed later) plays the
// default, so the ring is never silent for a name.
function pathFor(key, settings) {
  if (key === CUSTOM && settings && settings.soundFile) return String(settings.soundFile)
  return SOUND_DIR + (catalogEntry(key) ? key : DEFAULT_SOUND) + ".oga"
}

function soundPath(settings) {
  return pathFor(settings ? settings.sound : DEFAULT_SOUND, settings)
}

function baseName(path) {
  var parts = String(path || "").split("/")
  return parts[parts.length - 1]
}

// The Settings sections, in the order of the list.
var SECTIONS = [
  { id: "sound", label: "Alarm sound" },
  { id: "alarms", label: "Alarms" },
  { id: "history", label: "History" },
  { id: "data", label: "Data" }
]

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
// setting: { bytes }.
function sectionMeta(id, settings, info) {
  if (!settings) return ""
  if (id === "sound") return settings.soundOn ? soundName(settings) : "off"
  if (id === "alarms") return settings.snoozeMinutes + " / " + settings.ringMinutes + " min"
  if (id === "history") return keepText(settings.historyDays)
  if (id === "data") return sizeText(info ? info.bytes : 0)
  return ""
}

// "Bell", or the custom file's name.
function soundName(settings) {
  var key = settings ? settings.sound : DEFAULT_SOUND
  if (key === CUSTOM && settings.soundFile) return baseName(settings.soundFile)
  return (catalogEntry(key) || catalogEntry(DEFAULT_SOUND)).name
}
