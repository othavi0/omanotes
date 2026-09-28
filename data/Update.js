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
var BLOCKERS = ["dirty", "offMain", "diverged", "untracked", "notGit", "noOrigin"]

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
    to: s.to || "",
    request: s.request || ""
  }
}

// The one thing the section draws, and the gear's dot when it is
// "available". `local` is null until `status` answers. `running` is this
// Updater's own check, `requested` an apply asked for whose record has not
// shown up yet. A check counts only against the HEAD it was made on: after
// any pull, ours or `omarchy plugin update`, an old "3 new commits" is gone.
// phase: loading | none | unchecked | checking | upToDate | available |
// blocked | offline | updating | updated | failed.
function view(local, state, running, requested, nowMs) {
  var v = { phase: "unchecked", behind: 0, commits: [], error: "", detail: "", step: "", to: "", at: 0, canCheck: false, canUpdate: false }
  if (!local || !local.git) {
    v.phase = local ? "none" : "loading"
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
  if (requested) {
    v.phase = "updating"
    v.step = ""
  } else if (running) v.phase = "checking"
  else if (!state) v.phase = "unchecked"
  else if (state.phase === "updating") {
    if (nowMs - state.at > STALE_UPDATING_MS) {
      v.phase = "failed"
      v.error = "stopped"
    } else {
      v.phase = "updating"
    }
  } else if (state.phase === "updated") {
    // step "restart" is an update that pulled and waits for the new shell.
    // One that never recorded the restart's end reads as a failed restart.
    if (state.to !== local.head) v.phase = "unchecked"
    else if (state.step === "restart" && nowMs - state.at <= STALE_UPDATING_MS) v.phase = "updating"
    else {
      v.phase = "updated"
      if (state.step === "restart") {
        v.error = "restartFailed"
        v.step = ""
      }
    }
  } else if (state.phase === "failed") {
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
// or an hour since one that could not reach origin. `failedAtMs` is the
// last check that left no record, 0 for none; the record cannot say so, so
// without it such a check would run again every minute.
function dueForCheck(local, state, nowMs, failedAtMs) {
  if (!local || !local.git) return false
  if (failedAtMs && nowMs - failedAtMs < RETRY_OFFLINE_MS) return false
  if (!state) return true
  var age = nowMs - state.at
  return age >= DAY_MS || (state.error === "offline" && age >= RETRY_OFFLINE_MS)
}

// What the unit takes from the shell's environment, when set: the user
// manager has its own PATH and may lack the rest, and the validator, the
// restart, the notification and an ssh fetch need them. The restart finds
// Hyprland through HYPRLAND_INSTANCE_SIGNATURE and guesses the newest
// instance without it.
var UNIT_ENV = ["PATH", "XDG_STATE_HOME", "OMARCHY_PATH", "DBUS_SESSION_BUS_ADDRESS", "WAYLAND_DISPLAY", "SSH_AUTH_SOCK",
  "HYPRLAND_INSTANCE_SIGNATURE"]

// argv that runs apply outside the shell's process tree, so neither the
// reload the merge sets off nor the restart after it kills it. The unit's
// name is also the request each record of that apply carries. A test passes an empty launcher and runs
// the script directly. `envOf(key)` reads the shell's environment.
function applyCommand(launcher, unit, envOf, scriptPath, pluginDir) {
  var cmd = launcher.slice()
  if (cmd.length > 0) {
    cmd.push("--unit=" + unit)
    for (var i = 0; i < UNIT_ENV.length; ++i) {
      var value = envOf(UNIT_ENV[i])
      if (value) cmd.push("--setenv=" + UNIT_ENV[i] + "=" + value)
    }
  }
  return cmd.concat(["bash", scriptPath, "apply", pluginDir, unit])
}
