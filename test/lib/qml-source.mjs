// The plugin's QML as the static tests read it.
import { readdirSync } from "node:fs"

const root = new URL("../../", import.meta.url)
const SKIP = new Set([".git", ".claude", "node_modules", "test"])

export function qmlFiles(dir = "") {
  return readdirSync(new URL(dir || "./", root), { withFileTypes: true }).flatMap((entry) => {
    if (entry.isDirectory()) return SKIP.has(entry.name) ? [] : qmlFiles(dir + entry.name + "/")
    return entry.name.endsWith(".qml") ? [dir + entry.name] : []
  })
}

// `src` with its // and /* */ comments blanked out, newlines kept so line
// numbers hold. Quotes inside strings stay; quotes inside comments go.
export function withoutComments(src) {
  let out = ""
  let quote = null
  for (let i = 0; i < src.length; i++) {
    const c = src[i]
    if (quote) {
      out += c
      if (c === "\\") out += src[++i] ?? ""
      else if (c === quote) quote = null
      continue
    }
    if (c === "\\") {
      out += c + (src[++i] ?? "")
      continue
    }
    if (c === "/" && src[i + 1] === "/") {
      while (i < src.length && src[i] !== "\n") i++
      out += "\n"
      continue
    }
    if (c === "/" && src[i + 1] === "*") {
      const end = src.indexOf("*/", i + 2)
      const stop = end < 0 ? src.length : end + 2
      out += src.slice(i, stop).replace(/[^\n]/g, " ")
      i = stop - 1
      continue
    }
    if (c === '"' || c === "'" || c === "`") quote = c
    out += c
  }
  return out
}

