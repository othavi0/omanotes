import { test } from "node:test"
import assert from "node:assert/strict"
import { loadQmlLib } from "./lib/load-qml-lib.mjs"
import { cli, newDb, sync } from "./lib/bin-fixture.mjs"

const Sound = loadQmlLib(new URL("../data/Sound.js", import.meta.url), [
  "SOUND_DIR", "DEFAULT_SOUND", "CUSTOM", "SOUNDS", "catalogEntry", "pathFor", "soundPath", "nameOf", "soundName"
])
const Db = loadQmlLib(new URL("../data/Db.js", import.meta.url), ["SETTINGS"])

const DIR = "/usr/share/sounds/freedesktop/stereo/"

function settings(patch) {
  return { soundOn: true, sound: "alarm-clock-elapsed", soundFile: "", volume: 100, ...patch }
}

test("every catalog sound plays its freedesktop file, and the default is the alarm clock", () => {
  assert.deepEqual(Sound.SOUNDS.map((s) => s.name), ["Alarm clock", "Chime", "Complete", "Message", "Attention", "Bell"])
  for (const sound of Sound.SOUNDS) assert.equal(Sound.pathFor(sound.key, settings()), DIR + sound.key + ".oga")
  assert.equal(Sound.soundPath(settings()), DIR + "alarm-clock-elapsed.oga")
  assert.equal(Sound.soundPath(null), DIR + "alarm-clock-elapsed.oga", "a Db not read yet rings the default")
})

test("the settings row falls back to the catalog's default sound, and a new file starts on it", (t) => {
  assert.equal(Db.SETTINGS.sound.fallback, Sound.DEFAULT_SOUND)
  const path = newDb(t)
  assert.equal(sync(path).settings.sound, Sound.DEFAULT_SOUND)
  assert.equal(cli(path, "SELECT dflt_value FROM pragma_table_info('settings') WHERE name = 'sound'"), "'" + Sound.DEFAULT_SOUND + "'\n")
})

test("a custom sound plays the chosen file, and a custom sound with no file plays the default", () => {
  const custom = settings({ sound: "custom", soundFile: "/home/me/Music/ring me.ogg" })
  assert.equal(Sound.soundPath(custom), "/home/me/Music/ring me.ogg")
  assert.equal(Sound.soundName(custom), "ring me.ogg")
  assert.equal(Sound.soundPath(settings({ sound: "custom" })), DIR + "alarm-clock-elapsed.oga")
  assert.equal(Sound.soundName(settings({ sound: "custom" })), "Alarm clock")
})

// A relative path would reach the player as an argument it could read as an
// option, ffplay's "-autoexit" among them, and means no file the picker gave.
test("a custom file that is not an absolute path plays and reads as the default", () => {
  for (const soundFile of ["-autoexit", "Music/ring.ogg", "./ring.ogg", "~/ring.ogg"]) {
    const custom = settings({ sound: "custom", soundFile })
    assert.equal(Sound.soundPath(custom), DIR + "alarm-clock-elapsed.oga", soundFile)
    assert.equal(Sound.pathFor("custom", custom), DIR + "alarm-clock-elapsed.oga", soundFile)
    assert.equal(Sound.soundName(custom), "Alarm clock", soundFile)
  }
})

test("a sound the catalog does not know, from a hand edit, plays and reads as the default", () => {
  const unknown = settings({ sound: "incoming-call" })
  assert.equal(Sound.soundPath(unknown), DIR + "alarm-clock-elapsed.oga")
  assert.equal(Sound.soundName(unknown), "Alarm clock")
  assert.equal(Sound.soundName(settings({ sound: "bell" })), "Bell")
})

test("nameOf names the sound a key plays, whatever sound is picked", () => {
  const picked = settings({ sound: "bell", soundFile: "/home/me/gone.oga" })
  assert.equal(Sound.nameOf("service-login", picked), "Chime")
  assert.equal(Sound.nameOf("custom", picked), "gone.oga")
  assert.equal(Sound.nameOf("bell", picked), "Bell")
})
