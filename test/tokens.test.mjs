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
  assert.deepEqual(offending(/\bopacity:.*(?<![\w.])0?\.\d*[1-9]/), [])
  assert.deepEqual(offending(/Qt\.rgba\((?:[^,]+,){3}\s*[0-9.]+\s*\)/), [])
})

// Like offending(), but only hits whose innermost enclosing QML object is
// named `type`. Braces are counted line by line, so a one-line
// `Rectangle { width: 1 }` counts too.
function offendingInside(type, pattern) {
  const hits = []
  for (const file of files) {
    const stack = []
    file.src.split("\n").forEach(function(line, i) {
      const at = line.search(pattern)
      for (let j = 0; j <= line.length; j++) {
        if (j === at && stack[stack.length - 1] === type) hits.push(file.name + ":" + (i + 1) + ": " + line.trim())
        if (line[j] === "{") stack.push((line.slice(0, j).match(/([A-Z]\w*)\s*$/) || [])[1])
        else if (line[j] === "}") stack.pop()
      }
    })
  }
  return hits
}

test("hand-drawn 1px rules are PanelSeparator", () => {
  const size = "(?:width|height|implicitWidth|implicitHeight|Layout\\.(?:preferred|minimum|maximum)(?:Width|Height))"
  assert.deepEqual(offendingInside("Rectangle", new RegExp("(?<![\\w.])" + size + "\\s*:\\s*1\\s*(?:$|[;}])")), [])
})

test("corners follow Style.cornerRadius", () => {
  assert.deepEqual(offending(/radius:\s*Style\.space\(/), [])
})

test("glyphs come from Icons.js, not surrogate-pair literals", () => {
  assert.deepEqual(offending(/\\uD[89AB][0-9A-F]{2}/i), [])
})
