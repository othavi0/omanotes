import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { loadQmlLib } from "./lib/load-qml-lib.mjs"

const S = loadQmlLib(new URL("../ui/Settings.js", import.meta.url), [
  "SECTIONS", "snoozeCaption", "ringCaption", "sectionMeta", "KEEP_CHOICES", "keepText", "sizeText", "pathText",
  "PLUGIN_ID", "UPDATE_COMMANDS", "LISTING_URL", "updateCommandLine", "manifestVersion"
])

function settings(patch) {
  return { soundOn: true, sound: "alarm-clock-elapsed", soundFile: "", volume: 100, snoozeMinutes: 9, ringMinutes: 5,
    historyDays: 0, ...patch }
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

const MANIFEST = JSON.parse(readFileSync(new URL("../manifest.json", import.meta.url), "utf8"))

test("the Updates page names the installed version, and its row in the list repeats it", () => {
  assert.equal(S.manifestVersion(JSON.stringify(MANIFEST)), MANIFEST.version)
  assert.equal(S.manifestVersion(""), "")
  assert.equal(S.manifestVersion("{ not json"), "")
  assert.equal(S.manifestVersion('{"version": 12}'), "")
  assert.equal(S.sectionMeta("updates", settings(), { version: "1.2.0" }), "1.2.0")
  assert.equal(S.sectionMeta("updates", settings(), {}), "")
})

test("the update goes through Omarchy for this plugin's id, and the restart runs only when the update did not fail", () => {
  assert.equal(S.PLUGIN_ID, MANIFEST.id)
  assert.deepEqual(S.UPDATE_COMMANDS, ["omarchy plugin update othavi0.omanotes", "omarchy restart shell"])
  assert.equal(S.updateCommandLine(), "omarchy plugin update othavi0.omanotes && omarchy restart shell")
  assert.equal(S.LISTING_URL, "https://omarchyplugins.com/plugin.html?id=othavi0.omanotes")
})
