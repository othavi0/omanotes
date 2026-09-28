.pragma library

// What the Updates section shows, from two texts data/update.sh leaves: the
// `status` lines about the checkout and the state file of the last check or
// update (ADR-0017). No QML imports, so Node tests it (ADR-0009). Instants
// are epoch ms; the state file writes seconds.

var STALE_UPDATING_MS = 5 * 60 * 1000
var DAY_MS = 24 * 3600 * 1000
var RETRY_OFFLINE_MS = 3600 * 1000

// Refusals apply names before it touches anything. Update stays off until
// the user fixes the folder.
var BLOCKERS = ["dirty", "offMain", "diverged", "notGit", "noOrigin"]

// `key value` lines: only the first space splits. Repeated `commit` lines
// are gathered in order.
function parseLines(text) {
  var out = { commits: [] }
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; ++i) {
    var line = lines[i]
    if (line === "") continue
    var at = line.indexOf(" ")
    var key = at < 0 ? line : line.slice(0, at)
    var value = at < 0 ? "" : line.slice(at + 1)
    if (key === "commit") {
      var space = value.indexOf(" ")
      out.commits.push({ hash: space < 0 ? value : value.slice(0, space), subject: space < 0 ? "" : value.slice(space + 1) })
    } else if (!(key in out)) {
      out[key] = value
    }
  }
  return out
}

// `update.sh status` -> { git, version, branch, head, dirty }.
function parseLocal(text) {
  var l = parseLines(text)
  return { git: l.git === "1", version: l.version || "", branch: l.branch || "", head: l.head || "", dirty: l.dirty === "1" }
}

// The state file -> the record, or null when there is none to read.
function parseState(text) {
  var s = parseLines(text)
  if (!s.phase) return null
  return {
    phase: s.phase,
    at: (Number(s.at) || 0) * 1000,
    head: s.head || "",
    branch: s.branch || "",
    behind: Number(s.behind) || 0,
    commits: s.commits,
    error: s.error || "",
    detail: s.detail || "",
    step: s.step || "",
    from: s.from || "",
    to: s.to || ""
  }
}

// A check counts only against the HEAD it was made on: after any pull, ours
// or `omarchy plugin update`, an old "3 new commits" is gone.
function hasUpdate(local, state) {
  return !!local && !!state && state.phase === "checked" && state.behind > 0 && state.head === local.head
    && BLOCKERS.indexOf(state.error) < 0 && state.error !== "offline"
}

// The one thing the section draws. `running` is this Updater's own check.
// phase: none | unchecked | checking | upToDate | available | blocked |
// offline | updating | updated | failed.
function view(local, state, running, nowMs) {
  var v = { phase: "unchecked", behind: 0, commits: [], error: "", detail: "", step: "", to: "", at: 0, canCheck: false, canUpdate: false }
  if (!local || !local.git) {
    v.phase = "none"
    return v
  }
  if (state) {
    v.behind = state.behind
    v.commits = state.commits
    v.error = state.error
    v.detail = state.detail
    v.step = state.step
    v.to = state.to
    v.at = state.at
  }
  if (running) v.phase = "checking"
  else if (!state) v.phase = "unchecked"
  else if (state.phase === "updating") {
    if (nowMs - state.at > STALE_UPDATING_MS) {
      v.phase = "failed"
      v.error = "stopped"
    } else {
      v.phase = "updating"
    }
  } else if (state.phase === "updated") v.phase = state.to === local.head ? "updated" : "unchecked"
  else if (state.phase === "failed") {
    v.phase = state.error === "offline" ? "offline" : BLOCKERS.indexOf(state.error) >= 0 ? "blocked" : "failed"
  } else if (state.head !== local.head) v.phase = "unchecked"
  else if (state.error === "offline") v.phase = "offline"
  else if (BLOCKERS.indexOf(state.error) >= 0) v.phase = state.behind > 0 || state.error === "notGit" || state.error === "noOrigin" ? "blocked" : "upToDate"
  else v.phase = state.behind > 0 ? "available" : "upToDate"
  v.canCheck = v.phase !== "checking" && v.phase !== "updating"
  v.canUpdate = v.phase === "available"
  return v
}

// True when the daily check is owed: never checked, a day since the last,
// or an hour since one that could not reach origin.
function dueForCheck(local, state, nowMs) {
  if (!local || !local.git) return false
  if (!state) return true
  var age = nowMs - state.at
  return age >= DAY_MS || (state.error === "offline" && age >= RETRY_OFFLINE_MS)
}

// argv that runs apply outside the shell's process tree, so the reload the
// merge sets off does not kill it. A test passes an empty launcher and runs
// the script directly. `env` is copied into the unit, whose manager has its
// own PATH.
function applyCommand(launcher, unit, env, scriptPath, pluginDir) {
  var cmd = launcher.slice()
  if (cmd.length > 0) {
    cmd.push("--unit=" + unit)
    for (var key in env) if (env[key]) cmd.push("--setenv=" + key + "=" + env[key])
  }
  return cmd.concat(["bash", scriptPath, "apply", pluginDir])
}
