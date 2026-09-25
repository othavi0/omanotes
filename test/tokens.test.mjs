import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync, readdirSync } from "node:fs"

const ui = new URL("../ui/", import.meta.url)
const notYetMigrated = new Set(["Segment.qml", "PanelHeader.qml"])

const files = readdirSync(ui)
  .filter(function(name) { return name.endsWith(".qml") && !notYetMigrated.has(name) })
  .map(function(name) { return { name: "ui/" + name, src: readFileSync(new URL(name, ui), "utf8") } })
  .concat([{ name: "BarWidget.qml", src: readFileSync(new URL("../BarWidget.qml", import.meta.url), "utf8") }])

function offending(pattern) {
  const hits = []
  for (const file of files) {
    file.src.split("\n").forEach(function(line, i) {
      if (pattern.test(line)) hits.push(file.name + ":" + (i + 1) + ": " + line.trim())
    })
  }
  return hits
}

test("transparency comes from Style or Tone.js, never a number literal", () => {
  assert.deepEqual(offending(/Util\.alpha\([^,]+,\s*[0-9.]+\s*\)/), [])
})

test("hand-drawn 1px rules are PanelSeparator", () => {
  assert.deepEqual(offending(/^\s*height:\s*1\s*$/), [])
})

test("corners follow Style.cornerRadius", () => {
  assert.deepEqual(offending(/radius:\s*Style\.space\(/), [])
})

test("glyphs come from Icons.js, not surrogate-pair literals", () => {
  assert.deepEqual(offending(/\\uD[89AB][0-9A-F]{2}/i), [])
})
