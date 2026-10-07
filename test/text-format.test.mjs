// A Text without textFormat is AutoText: a title such as
// `<img src=http://...>` renders as rich text and fetches the image. Every
// Text of the plugin sets textFormat, literal or not, so a new one that
// shows user data cannot slip through.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync, readdirSync } from "node:fs"

const root = new URL("../", import.meta.url)
const files = ["", "ui/"].flatMap((dir) =>
  readdirSync(new URL(dir, root)).filter((name) => name.endsWith(".qml")).map((name) => dir + name))

// The body of the object that opens at `open`, the index of its `{`, with
// the text of nested objects cut out, so only its own properties are left.
function ownBody(src, open) {
  let depth = 0
  let out = ""
  let quote = null
  for (let i = open; i < src.length; i++) {
    const c = src[i]
    if (quote) {
      if (c === "\\") i++
      else if (c === quote) quote = null
      if (depth === 1) out += c
      continue
    }
    if (c === '"' || c === "'") quote = c
    if (c === "{") depth++
    else if (c === "}" && --depth === 0) return out
    else if (depth === 1) out += c
  }
  throw new Error("unbalanced braces after " + open)
}

function textsWithoutFormat(src) {
  const hits = []
  for (const m of src.matchAll(/(?<![\w.])Text\s*\{/g)) {
    const open = m.index + m[0].length - 1
    if (!/(^|\n)\s*textFormat\s*:/.test(ownBody(src, open))) hits.push(src.slice(0, m.index).split("\n").length)
  }
  return hits
}

test("the check finds a Text without textFormat and passes one with it", () => {
  assert.deepEqual(textsWithoutFormat('Item {\n  Text {\n    text: title\n    Rectangle { textFormat: 1 }\n  }\n}'), [2])
  assert.deepEqual(textsWithoutFormat('Item {\n  delegate: Text {\n    textFormat: Text.PlainText\n    text: "{"\n  }\n}'), [])
  assert.deepEqual(textsWithoutFormat("TextField {\n}\nQQC.Text {\n}\n"), [])
})

test("every Text in the plugin's QML sets textFormat", () => {
  const missing = files.flatMap((file) =>
    textsWithoutFormat(readFileSync(new URL(file, root), "utf8")).map((line) => file + ":" + line))
  assert.deepEqual(missing, [])
})
