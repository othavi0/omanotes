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
  { id: "alarms", label: "Alarms" }
]

// What a section row shows on its right, from the same settings the page
// edits: "Bell" or "off", "9 / 5 min".
function sectionMeta(id, settings) {
  if (!settings) return ""
  if (id === "sound") return settings.soundOn ? soundName(settings) : "off"
  if (id === "alarms") return settings.snoozeMinutes + " / " + settings.ringMinutes + " min"
  return ""
}

// "Bell", or the custom file's name.
function soundName(settings) {
  var key = settings ? settings.sound : DEFAULT_SOUND
  if (key === CUSTOM && settings.soundFile) return baseName(settings.soundFile)
  return (catalogEntry(key) || catalogEntry(DEFAULT_SOUND)).name
}
