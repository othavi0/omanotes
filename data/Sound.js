.pragma library

// The alarm sound catalog: which keys exist, what each is called and which
// file it plays. The service rings from it and the Settings page lists it.
// No QML imports, so Node tests it (ADR-0009). A new sound needs no
// migration: the settings row stores the key as text (ADR-0016).

var SOUND_DIR = "/usr/share/sounds/freedesktop/stereo/"
// Db.SETTINGS.sound.fallback repeats this key: Db.js cannot import under
// Node, and test/sound.test.mjs holds the two equal.
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

// The chosen file, or "" when there is none or it is not an absolute path.
// The picker gives absolute paths; anything else came from a hand edit, and
// a path starting with "-" would reach a player as an option.
function customFile(settings) {
  var file = settings && settings.soundFile ? String(settings.soundFile) : ""
  return file.charAt(0) === "/" ? file : ""
}

// The file a sound key plays. A custom key plays the chosen file, and a key
// the catalog does not know (a hand edit, a sound removed later) or a custom
// key without a usable file plays the default, so the ring is never silent
// for a name.
function pathFor(key, settings) {
  if (key === CUSTOM && customFile(settings) !== "") return customFile(settings)
  return SOUND_DIR + (catalogEntry(key) ? key : DEFAULT_SOUND) + ".oga"
}

function soundPath(settings) {
  return pathFor(settings ? settings.sound : DEFAULT_SOUND, settings)
}

function baseName(path) {
  var parts = String(path || "").split("/")
  return parts[parts.length - 1]
}

// What `key` plays, by name: "Bell", or the custom file's name. A key the
// catalog does not know reads as the default it plays.
function nameOf(key, settings) {
  if (key === CUSTOM && customFile(settings) !== "") return baseName(customFile(settings))
  return (catalogEntry(key) || catalogEntry(DEFAULT_SOUND)).name
}

// The name of the sound the ring plays.
function soundName(settings) {
  return nameOf(settings ? settings.sound : DEFAULT_SOUND, settings)
}
