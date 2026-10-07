// A Text or Label without textFormat is AutoText: a title such as
// `<img src=http://...>` renders as rich text and fetches the image. Every
// one in the plugin's QML says Text.PlainText, so a new one that shows user
// data cannot slip through.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { qmlFiles, withoutComments } from "./lib/qml-source.mjs"

const root = new URL("../", import.meta.url)

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
    if (c === '"' || c === "'" || c === "`") quote = c
    if (c === "{") depth++
    else if (c === "}" && --depth === 0) return out
    else if (depth === 1) out += c
  }
  throw new Error("unbalanced braces after " + open)
}

// The lines of each Text or Label, qualified or not, whose own body does not
// set textFormat: Text.PlainText.
export function textsNotPlain(source) {
  const src = withoutComments(source)
  const hits = []
  for (const m of src.matchAll(/(?<![\w.])(?:\w+\.)?(?:Text|Label)\s*\{/g)) {
    const open = m.index + m[0].length - 1
    if (!/(^|[\n;])\s*textFormat\s*:\s*Text\.PlainText\s*($|[\n;])/.test(ownBody(src, open))) {
      hits.push(src.slice(0, m.index).split("\n").length)
    }
  }
  return hits
}

test("the check finds what the one before it let through", () => {
  assert.deepEqual(textsNotPlain("Item {\n  Text { // the user's title\n    text: title\n  }\n  Text {\n    textFormat: Text.PlainText // isn't rich\n  }\n  // that's all\n}"), [2], "an apostrophe in a comment")
  assert.deepEqual(textsNotPlain("Item {\n  QQC.Label {\n    text: title\n  }\n  Ui.Text {\n    text: title\n  }\n}"), [2, 5],
    "a Label and a qualified Text")
  assert.deepEqual(textsNotPlain("Text {\n  textFormat: Text.AutoText\n}\nText {\n  textFormat: Text.StyledText\n}"), [1, 4],
    "a textFormat other than PlainText")
  assert.ok(qmlFiles().some((file) => file.startsWith("data/")), "the QML under data/ is read")
  assert.deepEqual(textsNotPlain('Item {\n  property var p: s.replace(/^file:\\/\\//, ""); Text {\n  }\n}'), [2], "an escaped slash is no comment")
})

test("the check passes a PlainText one and leaves other types alone", () => {
  assert.deepEqual(textsNotPlain('Item {\n  delegate: Text {\n    textFormat: Text.PlainText\n    text: "{ // not a comment"\n  }\n}'), [])
  assert.deepEqual(textsNotPlain("Text {\n  Rectangle { textFormat: Text.PlainText }\n}"), [1], "a nested object's textFormat is not its own")
  assert.deepEqual(textsNotPlain("TextField {\n}\nTextInput {\n}\nMyText {\n}\n/* Text { } */\n"), [])
})

test("every Text and Label in the plugin's QML is PlainText", () => {
  const files = qmlFiles()
  assert.ok(files.includes("ui/UpdateSettings.qml") && files.includes("BarWidget.qml"), files.join(" "))
  const missing = files.flatMap((file) => textsNotPlain(readFileSync(new URL(file, root), "utf8")).map((line) => file + ":" + line))
  assert.deepEqual(missing, [])
})
