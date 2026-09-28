import { test } from "node:test"
import assert from "node:assert/strict"
import { loadQmlLib } from "./lib/load-qml-lib.mjs"

const S = loadQmlLib(new URL("../ui/Settings.js", import.meta.url), [
  "SOUND_DIR", "DEFAULT_SOUND", "CUSTOM", "SOUNDS", "pathFor", "soundPath", "soundName", "SECTIONS", "sectionMeta", "KEEP_CHOICES", "keepText", "sizeText", "pathText", "versionText", "versionShort",
  "checkedAgoText", "updateHeadline", "updateSteps"
])

const DIR = "/usr/share/sounds/freedesktop/stereo/"

function settings(patch) {
  return { soundOn: true, sound: "alarm-clock-elapsed", soundFile: "", volume: 100, snoozeMinutes: 9, ringMinutes: 5,
    historyDays: 0, checkUpdates: true, ...patch }
}

test("every catalog sound plays its freedesktop file, and the default is the alarm clock", () => {
  assert.deepEqual(S.SOUNDS.map((s) => s.name), ["Alarm clock", "Chime", "Complete", "Message", "Attention", "Bell"])
  for (const sound of S.SOUNDS) assert.equal(S.pathFor(sound.key, settings()), DIR + sound.key + ".oga")
  assert.equal(S.soundPath(settings()), DIR + "alarm-clock-elapsed.oga")
  assert.equal(S.soundPath(null), DIR + "alarm-clock-elapsed.oga", "a Db not read yet rings the default")
})

test("a custom sound plays the chosen file, and a custom sound with no file plays the default", () => {
  const custom = settings({ sound: "custom", soundFile: "/home/me/Music/ring me.ogg" })
  assert.equal(S.soundPath(custom), "/home/me/Music/ring me.ogg")
  assert.equal(S.soundName(custom), "ring me.ogg")
  assert.equal(S.soundPath(settings({ sound: "custom" })), DIR + "alarm-clock-elapsed.oga")
  assert.equal(S.soundName(settings({ sound: "custom" })), "Alarm clock")
})

test("a sound the catalog does not know, from a hand edit, plays and reads as the default", () => {
  const unknown = settings({ sound: "incoming-call" })
  assert.equal(S.soundPath(unknown), DIR + "alarm-clock-elapsed.oga")
  assert.equal(S.soundName(unknown), "Alarm clock")
  assert.equal(S.soundName(settings({ sound: "bell" })), "Bell")
})

test("each section row names what its page holds, and the sound row reads off when the sound is off", () => {
  assert.deepEqual(S.SECTIONS.map((s) => s.label), ["Alarm sound", "Alarms", "Updates", "History", "Data"])
  assert.equal(S.sectionMeta("sound", settings({ sound: "bell" })), "Bell")
  assert.equal(S.sectionMeta("sound", settings({ sound: "bell", soundOn: false })), "off")
  assert.equal(S.sectionMeta("alarms", settings({ snoozeMinutes: 12, ringMinutes: 3 })), "12 / 3 min")
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
  assert.deepEqual(S.updateSteps({ step: "pull", behind: 3 }).map((s) => s.label + ":" + s.state),
    ["Fetching origin/main:done", "Pulling 3 commits:now", "Reloading the plugin:todo"])
})

test("checkedAgoText counts minutes, hours and days", () => {
  const now = 1759066800000
  assert.equal(S.checkedAgoText(0, now), "Not checked yet")
  assert.equal(S.checkedAgoText(now - 20000, now), "Checked just now")
  assert.equal(S.checkedAgoText(now - 5 * 60000, now), "Checked 5 min ago")
  assert.equal(S.checkedAgoText(now - 2 * 3600000, now), "Checked 2 h ago")
  assert.equal(S.checkedAgoText(now - 3 * 86400000, now), "Checked 3 d ago")
})
