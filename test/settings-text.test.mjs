import { test } from "node:test"
import assert from "node:assert/strict"
import { loadQmlLib } from "./lib/load-qml-lib.mjs"

const S = loadQmlLib(new URL("../ui/Settings.js", import.meta.url), [
  "SOUND_DIR", "DEFAULT_SOUND", "CUSTOM", "SOUNDS", "pathFor", "soundPath", "soundName"
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
