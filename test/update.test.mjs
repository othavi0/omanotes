import { test } from "node:test"
import assert from "node:assert/strict"
import { loadQmlLib } from "./lib/load-qml-lib.mjs"

const U = loadQmlLib(new URL("../data/Update.js", import.meta.url), [
  "STALE_UPDATING_MS", "DAY_MS", "RETRY_OFFLINE_MS", "parseLocal", "parseState", "hasUpdate", "view", "dueForCheck", "applyCommand"
])

const NOW = 1759066800000
const LOCAL = { git: true, version: "1.1.0", branch: "main", head: "4e06360", dirty: false }

function stateText(fields, commits = []) {
  const f = { phase: "checked", at: NOW / 1000 - 60, head: "4e06360", branch: "main", behind: 0, error: "", detail: "", step: "", from: "", to: "", ...fields }
  return Object.entries(f).map(([k, v]) => k + " " + v).concat(commits.map((c) => "commit " + c)).join("\n") + "\n"
}

test("parseLocal reads the status lines, and a folder that is no checkout", () => {
  assert.deepEqual(U.parseLocal("git 1\nversion 1.1.0\nbranch main\nhead 4e06360\ndirty 0\n"), LOCAL)
  assert.deepEqual(U.parseLocal("git 0\nversion 1.1.0\n"), { git: false, version: "1.1.0", branch: "", head: "", dirty: false })
  assert.deepEqual(U.parseLocal(""), { git: false, version: "", branch: "", head: "", dirty: false })
})

test("parseState keeps a subject with spaces, quotes and a tab whole, in order", () => {
  const s = U.parseState(stateText({ behind: 2 }, ["c41e9a2 feat(alarm): aba \"Alarms\"\te som", "7b0d113 fix: busca"]))
  assert.equal(s.phase, "checked")
  assert.equal(s.at, NOW - 60000, "seconds become ms")
  assert.equal(s.behind, 2)
  assert.deepEqual(s.commits, [{ hash: "c41e9a2", subject: "feat(alarm): aba \"Alarms\"\te som" }, { hash: "7b0d113", subject: "fix: busca" }])
  assert.equal(U.parseState(""), null)
  assert.equal(U.parseState("garbage without a phase\n"), null)
})

test("view: one phase for each record the script leaves", () => {
  const phase = (fields, running = false, local = LOCAL) => U.view(local, fields === null ? null : U.parseState(stateText(fields)), running, NOW).phase
  assert.equal(phase(null), "unchecked")
  assert.equal(phase({ behind: 0 }), "upToDate")
  assert.equal(phase({ behind: 3 }), "available")
  assert.equal(phase({ behind: 3 }, true), "checking")
  assert.equal(phase({ behind: 3, error: "dirty" }), "blocked")
  assert.equal(phase({ behind: 0, error: "dirty" }), "upToDate", "local changes with nothing new block nothing")
  assert.equal(phase({ behind: 1, error: "offMain", branch: "feat/x" }), "blocked")
  assert.equal(phase({ behind: 1, error: "diverged" }), "blocked")
  assert.equal(phase({ behind: 1, error: "untracked" }), "blocked")
  assert.equal(phase({ phase: "failed", error: "mergeFailed" }), "failed")
  assert.equal(phase({ error: "offline" }), "offline")
  assert.equal(phase({ error: "noOrigin" }), "blocked")
  assert.equal(phase({ phase: "failed", error: "dirty" }), "blocked")
  assert.equal(phase({ phase: "failed", error: "offline" }), "offline")
  assert.equal(phase({ phase: "failed", error: "invalid" }), "failed")
  assert.equal(phase({ phase: "updating", step: "pull" }), "updating")
  assert.equal(phase({ phase: "updated", to: "4e06360" }), "updated")
  assert.equal(phase({ phase: "updated", to: "c41e9a2" }), "unchecked", "a later pull makes the old result stale")
  assert.equal(phase({ behind: 3 }, false, { ...LOCAL, git: false }), "none")
})

test("view: an update that stopped writing for five minutes reads as failed, not updating forever", () => {
  const stale = U.parseState(stateText({ phase: "updating", step: "pull", at: (NOW - U.STALE_UPDATING_MS - 1000) / 1000 }))
  const v = U.view(LOCAL, stale, false, NOW)
  assert.deepEqual([v.phase, v.error, v.canCheck, v.canUpdate], ["failed", "stopped", true, false])
})

test("view: Update is offered only for new commits nothing blocks, Check whenever nothing runs", () => {
  const v = (fields, running = false) => U.view(LOCAL, U.parseState(stateText(fields)), running, NOW)
  assert.deepEqual([v({ behind: 3 }).canUpdate, v({ behind: 3 }).canCheck], [true, true])
  assert.equal(v({ behind: 3, error: "dirty" }).canUpdate, false)
  assert.equal(v({ behind: 3 }, true).canCheck, false)
  assert.equal(v({ phase: "updating", step: "fetch" }).canCheck, false)
  assert.equal(U.view({ ...LOCAL, git: false }, null, false, NOW).canCheck, false)
})

test("hasUpdate: only a check made on the current HEAD, with new commits and nothing in the way", () => {
  const s = (fields) => U.parseState(stateText(fields))
  assert.equal(U.hasUpdate(LOCAL, s({ behind: 3 })), true)
  assert.equal(U.hasUpdate({ ...LOCAL, head: "c41e9a2" }, s({ behind: 3 })), false, "HEAD moved since the check")
  assert.equal(U.hasUpdate(LOCAL, s({ behind: 0 })), false)
  assert.equal(U.hasUpdate(LOCAL, s({ behind: 3, error: "dirty" })), false)
  assert.equal(U.hasUpdate(LOCAL, null), false)
})

test("dueForCheck: never checked, a day old, or an offline hour old, and never without git", () => {
  const s = (ageMs, error = "") => U.parseState(stateText({ at: (NOW - ageMs) / 1000, error }))
  assert.equal(U.dueForCheck(LOCAL, null, NOW), true)
  assert.equal(U.dueForCheck(LOCAL, s(U.DAY_MS - 60000), NOW), false)
  assert.equal(U.dueForCheck(LOCAL, s(U.DAY_MS), NOW), true)
  assert.equal(U.dueForCheck(LOCAL, s(U.RETRY_OFFLINE_MS - 60000, "offline"), NOW), false)
  assert.equal(U.dueForCheck(LOCAL, s(U.RETRY_OFFLINE_MS, "offline"), NOW), true)
  assert.equal(U.dueForCheck({ ...LOCAL, git: false }, null, NOW), false)
})

test("applyCommand runs the script in its own unit with the shell's PATH, or directly with no launcher", () => {
  assert.deepEqual(U.applyCommand(["systemd-run", "--user", "--collect", "--quiet"], "omanotes-update-7", { PATH: "/usr/bin:/opt/bin", XDG_STATE_HOME: "" },
    "/p/data/update.sh", "/p"),
    ["systemd-run", "--user", "--collect", "--quiet", "--unit=omanotes-update-7", "--setenv=PATH=/usr/bin:/opt/bin",
      "bash", "/p/data/update.sh", "apply", "/p"])
  assert.deepEqual(U.applyCommand([], "x", { PATH: "/usr/bin" }, "/p/data/update.sh", "/p"), ["bash", "/p/data/update.sh", "apply", "/p"])
})
