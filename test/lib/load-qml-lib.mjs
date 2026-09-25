import { readFileSync } from "node:fs"

// Loads a `.pragma library` QML JS module under Node: strip the pragma line
// (the only QML-specific syntax these files use) and evaluate the rest with
// `new Function`, returning the requested top-level names. A name the file
// does not define comes back undefined, so only the tests that use it fail.
export function loadQmlLib(path, names) {
  const src = readFileSync(path, "utf8").replace(/^\s*\.pragma library\s*$/m, "")
  const body = src + "\nreturn { "
    + names.map(function(n) { return n + ": typeof " + n + " === 'undefined' ? undefined : " + n }).join(", ") + " };"
  return new Function(body)()
}
