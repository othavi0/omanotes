// Every program the plugin starts is named by its full path, so a program of
// the same name earlier in the PATH the shell inherited never runs, and
// nothing goes through Util.execArgv, which runs `bash -lc` and reads the
// user's login files (docs/development.md).
import { test } from "node:test"
import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { readFileSync } from "node:fs"
import { withoutComments } from "./lib/qml-source.mjs"

const root = new URL("../", import.meta.url)

function versionedQml() {
  return execFileSync("git", ["ls-files", "*.qml"], { cwd: root, encoding: "utf8" })
    .split("\n").filter((file) => file !== "" && !file.startsWith("test/"))
}

// Each spawn whose program is a literal without a slash, and each execArgv.
export function spawnsByName(source) {
  const src = withoutComments(source)
  const lineOf = (index) => src.slice(0, index).split("\n").length
  const hits = []
  for (const m of src.matchAll(/\bexecArgv\b/g)) hits.push(lineOf(m.index) + " execArgv")
  for (const m of src.matchAll(/(?:\bcommand\s*:|\bexecDetached\s*\()\s*\[\s*(["'`])((?:\\.|(?!\1).)*)\1/g)) {
    if (!m[2].includes("/")) hits.push(lineOf(m.index) + " " + m[2])
  }
  return hits
}

test("the check finds a program by name and execArgv, and passes a full path or a property", () => {
  assert.deepEqual(spawnsByName('Process {\n  command: ["omarchy-file-select", "--title"]\n}'), ["2 omarchy-file-select"])
  assert.deepEqual(spawnsByName("onClicked: Quickshell.execDetached([ 'xdg-open', dir ])"), ["1 xdg-open"])
  assert.deepEqual(spawnsByName('onClicked: Util.execArgv(["/usr/bin/xdg-open", dir])'), ["1 execArgv"])
  assert.deepEqual(spawnsByName('command: ["/usr/bin/wl-copy"]\ncommand: [root.bashPath, "-c", s]\n// command: ["bash"]'), [])
})

test("no QML of the plugin starts a program by name or through execArgv", () => {
  const files = versionedQml()
  assert.ok(files.includes("Service.qml") && files.includes("ui/SoundSettings.qml"), files.join(" "))
  const hits = files.flatMap((file) => spawnsByName(readFileSync(new URL(file, root), "utf8")).map((hit) => file + ":" + hit))
  assert.deepEqual(hits, [])
})
