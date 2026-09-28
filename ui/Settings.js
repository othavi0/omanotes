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
// setting: { sound, bytes, version, hasUpdate }, `sound` being the name of
// the sound the ring plays.
function sectionMeta(id, settings, info) {
  if (!settings) return ""
  if (id === "sound") return settings.soundOn ? (info ? info.sound : "") : "off"
  if (id === "alarms") return settings.snoozeMinutes + " / " + settings.ringMinutes + " min"
  if (id === "history") return keepText(settings.historyDays)
  if (id === "data") return sizeText(info ? info.bytes : 0)
  if (id === "updates") return info && info.hasUpdate ? "new" : (info && info.version) || ""
  return ""
}

// The state file keeps whole hashes; the page shows seven characters.
function shortHash(hash) {
  return String(hash || "").slice(0, 7)
}

// "1.1.0 · main · 4e06360", the Version row.
function versionText(local) {
  if (!local) return ""
  return [local.version, local.git ? local.branch : "not a git checkout", shortHash(local.head)].filter(function(p) { return p !== "" }).join(" · ")
}

// "1.1.0 · 4e06360", the header while Settings is open.
function versionShort(local) {
  if (!local) return ""
  return [local.version, shortHash(local.head)].filter(function(p) { return p !== "" }).join(" · ")
}

function commitsText(n) {
  return n + " new commit" + (n === 1 ? "" : "s")
}

// "Checked just now", "Checked 5 min ago", "Checked 2 h ago", "Checked 3 d ago".
function checkedAgoText(atMs, nowMs) {
  if (!atMs) return "Not checked yet"
  var minutes = Math.floor(Math.max(0, nowMs - atMs) / 60000)
  if (minutes < 1) return "Checked just now"
  if (minutes < 60) return "Checked " + minutes + " min ago"
  if (minutes < 24 * 60) return "Checked " + Math.floor(minutes / 60) + " h ago"
  return "Checked " + Math.floor(minutes / (24 * 60)) + " d ago"
}

var REFUSALS = {
  dirty: "The plugin folder has local changes, so pulling could lose them. Nothing was changed.",
  offMain: "The plugin folder is not on main. Nothing was changed.",
  diverged: "The plugin folder has commits that origin/main lacks. Nothing was changed.",
  untracked: "The plugin folder has untracked files that the update would overwrite. Nothing was changed.",
  notGit: "The plugin folder is not a git checkout of its own.",
  noOrigin: "The plugin folder has no origin to pull from."
}

// The line the Updates section leads with, for view.phase.
function updateHeadline(view, local) {
  switch (view.phase) {
  case "loading": return "Reading the plugin folder…"
  case "none": return "This copy is not a git checkout, so it cannot update itself. Install it with omarchy plugin add to get updates."
  case "unchecked": return "Not checked yet"
  case "checking": return "Checking origin/main…"
  case "upToDate": return "You have the latest version."
  case "available": return commitsText(view.behind) + " on origin/main"
  case "blocked": return REFUSALS[view.error] || "Nothing was changed."
  case "offline": return view.detail ? "Could not reach origin: " + view.detail : "Could not reach origin. Check the connection and try again."
  case "updating": return "Updating to " + shortHash(view.to) + "…"
  case "updated": return "Updated to " + shortHash(view.to) + ". The plugin reloaded."
  }
  var stayed = "so the plugin stayed at " + (local ? shortHash(local.head) : "its version")
  if (view.error === "invalid") return "The new version did not validate, " + stayed + (view.detail ? ": " + view.detail : ".")
  if (view.error === "mergeFailed") return "git refused the pull, " + stayed + (view.detail ? ": " + view.detail : ".")
  if (view.error === "stopped") return "The update stopped before it finished."
  return "The update failed" + (view.detail ? ": " + view.detail : ".")
}

// The steps of an update in progress, each done, now or todo. The plugin
// reloads right after the pull, and the panel closes with it.
function updateSteps(view) {
  var steps = [{ key: "fetch", label: "Fetching origin/main" }, { key: "validate", label: "Validating the new version" },
    { key: "pull", label: "Pulling " + commitsText(view.behind).replace(" new", "") }]
  var at = steps.map(function(s) { return s.key }).indexOf(view.step)
  return steps.map(function(s, i) { return { label: s.label, state: i < at ? "done" : i === at ? "now" : "todo" } })
}
