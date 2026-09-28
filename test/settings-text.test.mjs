import { test } from "node:test"
import assert from "node:assert/strict"
import { loadQmlLib } from "./lib/load-qml-lib.mjs"

const S = loadQmlLib(new URL("../ui/Settings.js", import.meta.url), [
  "SECTIONS", "snoozeCaption", "ringCaption", "sectionMeta", "KEEP_CHOICES", "keepText", "sizeText", "pathText", "versionText", "versionShort", "shortHash",
  "checkedAgoText", "updateHeadline", "updateSteps"
])

function settings(patch) {
  return { soundOn: true, sound: "alarm-clock-elapsed", soundFile: "", volume: 100, snoozeMinutes: 9, ringMinutes: 5,
    historyDays: 0, checkUpdates: true, ...patch }
}

test("each section row names what its page holds, and the sound row reads off when the sound is off", () => {
  assert.deepEqual(S.SECTIONS.map((s) => s.label), ["Alarm sound", "Alarms", "Updates", "History", "Data"])
  assert.equal(S.sectionMeta("sound", settings({ sound: "bell" }), { sound: "Bell" }), "Bell")
  assert.equal(S.sectionMeta("sound", settings({ sound: "bell", soundOn: false }), { sound: "Bell" }), "off")
  assert.equal(S.sectionMeta("alarms", settings({ snoozeMinutes: 12, ringMinutes: 3 })), "12 / 3 min")
})

test("the stepper captions name the range the settings row takes", () => {
  const Db = loadQmlLib(new URL("../data/Db.js", import.meta.url), ["SETTINGS"])
  assert.equal(S.snoozeCaption(Db.SETTINGS), "Length of Snooze on the ring card. 1 to 180 min.")
  assert.equal(S.ringCaption(Db.SETTINGS), "Rings this long, then snoozes by itself. 1 to 60 min.")
})

test("the Keep choice reads forever or a number of days", () => {
  assert.deepEqual(S.KEEP_CHOICES.map((c) => c.label), ["Forever", "90 days", "30 days"])
  assert.equal(S.sectionMeta("history", settings({ historyDays: 0 })), "forever")
  assert.equal(S.sectionMeta("history", settings({ historyDays: 30 })), "30d")
})

test("the Data row reads the file size in the unit that fits, and the path from home", () => {
  assert.equal(S.sizeText(900), "900 B")
  assert.equal(S.sizeText(217088), "212 KB")
  assert.equal(S.sizeText(5 * 1048576 + 300000), "5.3 MB")
  assert.equal(S.sectionMeta("data", settings(), { bytes: 217088 }), "212 KB")
  assert.equal(S.pathText("/home/me/.local/share/omarchy/scratchpad.db", "/home/me"), "~/.local/share/omarchy/scratchpad.db")
  assert.equal(S.pathText("/data/omarchy/scratchpad.db", "/home/me"), "/data/omarchy/scratchpad.db")
})

const LOCAL = { git: true, version: "1.1.0", branch: "main", head: "4e06360", dirty: false }

test("the version reads the manifest version, the branch and the head", () => {
  assert.equal(S.versionText(LOCAL), "1.1.0 · main · 4e06360")
  assert.equal(S.versionShort(LOCAL), "1.1.0 · 4e06360")
  assert.equal(S.versionText({ git: false, version: "1.1.0", branch: "", head: "", dirty: false }), "1.1.0 · not a git checkout")
  assert.equal(S.sectionMeta("updates", settings(), { version: "1.1.0", hasUpdate: false }), "1.1.0")
  assert.equal(S.sectionMeta("updates", settings(), { version: "1.1.0", hasUpdate: true }), "new")
})

test("the Updates headline names what happened and what the user can do", () => {
  const view = (phase, fields) => ({ phase, behind: 0, commits: [], error: "", detail: "", step: "", to: "", ...fields })
  assert.equal(S.updateHeadline(view("available", { behind: 3 }), LOCAL), "3 new commits on origin/main")
  assert.equal(S.updateHeadline(view("available", { behind: 1 }), LOCAL), "1 new commit on origin/main")
  assert.equal(S.updateHeadline(view("blocked", { error: "dirty" }), LOCAL),
    "The plugin folder has local changes, so pulling could lose them. Nothing was changed.")
  assert.equal(S.updateHeadline(view("updated", { to: "c41e9a2" }), LOCAL), "Updated to c41e9a2. The plugin reloaded.")
  assert.equal(S.updateHeadline(view("failed", { error: "invalid" }), LOCAL), "The new version did not validate, so the plugin stayed at 4e06360.")
  assert.equal(S.updateHeadline(view("failed", { error: "stopped" }), LOCAL), "The update stopped before it finished.")
  assert.equal(S.updateHeadline(view("upToDate"), LOCAL), "You have the latest version.")
})

test("an update in progress marks the steps done, now and todo", () => {
  assert.deepEqual(S.updateSteps({ step: "validate", behind: 3 }).map((s) => s.label + ":" + s.state),
    ["Fetching origin/main:done", "Validating the new version:now", "Pulling 3 commits:todo"])
})

test("the state file's whole hashes read as seven characters", () => {
  const full = "4e06360b8a2c9d1e0f3a4b5c6d7e8f9a0b1c2d3e"
  const local = { ...LOCAL, head: full }
  assert.equal(S.shortHash(full), "4e06360")
  assert.equal(S.versionText(local), "1.1.0 · main · 4e06360")
  assert.equal(S.versionShort(local), "1.1.0 · 4e06360")
  const view = (phase, fields) => ({ phase, behind: 0, commits: [], error: "", detail: "", step: "", to: "", ...fields })
  assert.equal(S.updateHeadline(view("updating", { to: "c41e9a2f00d1" }), local), "Updating to c41e9a2…")
  assert.equal(S.updateHeadline(view("updated", { to: "c41e9a2f00d1" }), local), "Updated to c41e9a2. The plugin reloaded.")
  assert.equal(S.updateHeadline(view("failed", { error: "invalid" }), local), "The new version did not validate, so the plugin stayed at 4e06360.")
})

test("offline, invalid and a refused merge carry the tool's own reason", () => {
  const view = (phase, fields) => ({ phase, behind: 0, commits: [], error: "", detail: "", step: "", to: "", ...fields })
  assert.equal(S.updateHeadline(view("offline", { error: "offline", detail: "fatal: repository '/x/gone.git' does not exist" }), LOCAL),
    "Could not reach origin: fatal: repository '/x/gone.git' does not exist")
  assert.equal(S.updateHeadline(view("offline", { error: "offline" }), LOCAL), "Could not reach origin. Check the connection and try again.")
  assert.equal(S.updateHeadline(view("failed", { error: "invalid", detail: "omarchy-plugin-validate: missing manifest.json" }), LOCAL),
    "The new version did not validate, so the plugin stayed at 4e06360: omarchy-plugin-validate: missing manifest.json")
  assert.equal(S.updateHeadline(view("failed", { error: "mergeFailed", detail: "fatal: Unable to create '.git/index.lock': File exists." }), LOCAL),
    "git refused the pull, so the plugin stayed at 4e06360: fatal: Unable to create '.git/index.lock': File exists.")
})

test("a copy that is no checkout is told how to get one, and a page still reading says so", () => {
  assert.equal(S.updateHeadline({ phase: "none" }, null),
    "This copy is not a git checkout, so it cannot update itself. Install it with omarchy plugin add to get updates.")
  assert.equal(S.updateHeadline({ phase: "loading" }, null), "Reading the plugin folder…")
})

test("an untracked file that the update would overwrite blocks it", () => {
  assert.equal(S.updateHeadline({ phase: "blocked", error: "untracked" }, LOCAL),
    "The plugin folder has untracked files that the update would overwrite. Nothing was changed.")
  assert.equal(S.updateHeadline({ phase: "blocked", error: "untracked", detail: "sub" }, LOCAL),
    "The plugin folder has untracked files that the update would overwrite, such as sub. Nothing was changed.")
})

test("checkedAgoText counts minutes, hours and days", () => {
  const now = 1759066800000
  assert.equal(S.checkedAgoText(0, now), "Not checked yet")
  assert.equal(S.checkedAgoText(now - 20000, now), "Checked just now")
  assert.equal(S.checkedAgoText(now - 5 * 60000, now), "Checked 5 min ago")
  assert.equal(S.checkedAgoText(now - 2 * 3600000, now), "Checked 2 h ago")
  assert.equal(S.checkedAgoText(now - 3 * 86400000, now), "Checked 3 d ago")
})
