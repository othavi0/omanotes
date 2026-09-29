// data/Db.js on its own: the ids and numbers the wire takes, the rows a view
// shows, the request the Store writes on stdin, what an answer means and the
// words a failure shows. The request and the words are also held against the
// binary itself.
import { test } from "node:test"
import assert from "node:assert/strict"
import { BUILD, Db, T0, exec, newDb, rows, run, sync } from "./lib/bin-fixture.mjs"

function ids(list) {
  return list.map((r) => r.id)
}

test("wholeId takes a whole number as a number or as digits and refuses the rest with the IPC's words", () => {
  assert.equal(Db.wholeId(5), 5)
  assert.equal(Db.wholeId("12"), 12)
  for (const id of ["abc", "", "1.5", "-1", "2 OR 1=1", null, undefined, NaN, true]) {
    assert.throws(() => Db.wholeId(id), { message: "invalid id: " + id })
  }
})

test("wholeIn accepts a whole number inside its range and refuses everything else", () => {
  assert.equal(Db.wholeIn(7, 0, 23), 7)
  assert.equal(Db.wholeIn("23", 0, 23), 23)
  assert.equal(Db.wholeIn(0, 0, 23), 0)
  for (const v of [24, -1, 1.5, "7.0x", "", null, undefined, NaN, true, "1e2", " 7"]) {
    assert.throws(() => Db.wholeIn(v, 0, 23), { message: "invalid value: " + v }, String(v))
  }
})

test("now is Unix seconds, rounded down", () => {
  const real = Date.now
  Date.now = () => T0 * 1000 + 999
  try {
    assert.equal(Db.now(), T0)
  } finally {
    Date.now = real
  }
})

test("movedRows: the list with the item moved before or after another, the same list when either is missing", () => {
  const list = [{ id: 1 }, { id: 2 }, { id: 3 }, { id: 4 }]
  assert.deepEqual(ids(Db.movedRows(list, 3, 1, false)), [3, 1, 2, 4])
  assert.deepEqual(ids(Db.movedRows(list, 1, 3, true)), [2, 3, 1, 4])
  assert.deepEqual(ids(Db.movedRows(list, "4", "2", true)), [1, 2, 4, 3])
  assert.deepEqual(ids(Db.movedRows(list, 9, 1, false)), [1, 2, 3, 4])
  assert.deepEqual(ids(Db.movedRows(list, 1, 9, false)), [1, 2, 3, 4])
  assert.deepEqual(ids(list), [1, 2, 3, 4])
})

test("typeRows narrows every item to a type in the same order; any other filter is every item, the same array", () => {
  const all = [{ id: 1, type: "todo" }, { id: 2, type: "note" }, { id: 3, type: "todo" }]
  assert.deepEqual(ids(Db.typeRows(all, "todo")), [1, 3])
  assert.deepEqual(ids(Db.typeRows(all, "note")), [2])
  assert.equal(Db.typeRows(all, "all"), all)
  assert.equal(Db.typeRows(all, "bogus"), all)
})

test("matchedRows looks the matched ids up in the snapshot, and skips one it does not hold", () => {
  const byId = { 1: { id: 1 }, 2: { id: 2 }, 3: { id: 3 } }
  assert.deepEqual(ids(Db.matchedRows(byId, [3, 9, 1])), [3, 1])
})

test("viewQuery trims a search and cuts it to MAX_QUERY units, which SQLite always takes", (t) => {
  assert.equal(Db.MAX_QUERY, 200)
  assert.equal(Db.viewQuery("  cafe  "), "cafe")
  assert.equal(Db.viewQuery(" " + "x".repeat(300)), "x".repeat(200))
  assert.equal(Db.viewQuery(""), "")
  // U+0958 folds to the longest UTF-8 of the fold table: 6 bytes, 200 of them far under the 50 000 of a LIKE pattern.
  const path = newDb(t)
  const snap = sync(path, -1, [{ key: "v", filter: "all", query: Db.viewQuery("क़".repeat(60000)) }])
  assert.deepEqual(snap.matches, { v: [] })
})

test("sameRows compares two lists row by row and field by field, so a snapshot with the same rows changes nothing", () => {
  const row = (id, title) => ({ id, type: "note", title, body: null, status: 0, created_at: 1, updated_at: 2 })
  const shown = [row(1, "a"), row(2, "b")]
  assert.equal(Db.sameRows(shown, [row(1, "a"), row(2, "b")]), true)
  assert.equal(Db.sameRows([], []), true)
  assert.equal(Db.sameRows(shown, [row(2, "b"), row(1, "a")]), false, "the order counts")
  assert.equal(Db.sameRows(shown, [row(1, "a")]), false)
  assert.equal(Db.sameRows(shown, [row(1, "a"), row(2, "B")]), false)
  assert.equal(Db.sameRows(shown, [row(1, "a"), { ...row(2, "b"), updated_at: 3 }]), false)
})

test("definitive is true for the failures a retry would get again", () => {
  for (const err of ["bad_request", "forbidden", "too_large", "refused"]) assert.equal(Db.definitive(err), true, err)
  for (const err of ["busy", "io", "corrupt", "sqlite", "internal", "crash", "no_binary", "timeout", "protocol", "not_found"]) {
    assert.equal(Db.definitive(err), false, err)
  }
})

test("parseCounts of no row counts zero", () => {
  assert.deepEqual(Db.parseCounts(null), { unreadNotes: 0, pendingTodos: 0, notes: 0, todos: 0, history: 0, oldestHistory: 0 })
})

test("wellFormed replaces each lone surrogate with U+FFFD and keeps pairs", () => {
  const codes = (s) => [...s].map((c) => c.codePointAt(0).toString(16)).join(" ")
  assert.equal(codes(Db.wellFormed("a\ud800b\udc00c😀")), "61 fffd 62 fffd 63 1f600")
  assert.equal(codes(Db.wellFormed("\udc00\udc00")), "fffd fffd")
  assert.equal(codes(Db.wellFormed("\ud800𐀀")), "fffd 10000")
  assert.equal(Db.wellFormed("plain ação"), "plain ação")
})

test("request carries the writes and the sync, with every text well formed", () => {
  const body = JSON.parse(Db.request([{ id: 1, by: "widget", op: "item.add", at: T0, args: { type: "note", title: "a\ud800", body: "" } }],
    { since: -1, views: [{ key: "v1", filter: "all", query: "b\udc00" }] }))
  assert.equal(body.writes[0].args.title, "a�")
  assert.equal(body.sync.views[0].query, "b�")
  assert.deepEqual(Object.keys(JSON.parse(Db.request([], { since: 3, views: [] }))), ["sync"])
})

test("a lone surrogate in a title reaches the file as U+FFFD, where the raw text would be refused", (t) => {
  const path = newDb(t)
  const write = { id: 1, by: "widget", op: "item.add", at: T0, args: { type: "note", title: "x\ud800y", body: "" } }
  const raw = exec([String(Db.PROTOCOL), "run", path], JSON.stringify({ writes: [write] }))
  assert.equal(JSON.parse(raw.stdout).results[0].err, "bad_request")
  const r = exec([String(Db.PROTOCOL), "run", path], Db.request([write], null))
  assert.equal(r.status, 0, r.stderr)
  assert.equal(rows(path, "SELECT title FROM items")[0].title, "x�y")
})

test("command puts no user text in argv: the binary, the protocol, the verb and the file", () => {
  assert.deepEqual(Db.command("/p/bin/omanotes-db.x86_64", "/d/scratchpad.db"), ["/p/bin/omanotes-db.x86_64", "1", "run", "/d/scratchpad.db"])
  assert.ok(BUILD.protocol[0] <= Db.PROTOCOL && Db.PROTOCOL <= BUILD.protocol[1], "the committed binary speaks the QML's protocol")
})

test("utf8Length counts the bytes a text takes on stdin", () => {
  assert.equal(Db.utf8Length("abc"), 3)
  assert.equal(Db.utf8Length("ação"), 6)
  assert.equal(Db.utf8Length("😀"), 4)
})

test("reply reads line 1 as the results and line 2 as the snapshot on exit 0, with stderr as the log", () => {
  const results = JSON.stringify({ results: [{ id: 1, value: 7 }] })
  assert.deepEqual(Db.reply(0, false, results + "\n" + JSON.stringify({ stamp: 3, unchanged: true, matches: {} }) + "\n", "omanotes-db: migrated 0 -> 5\n"),
    { ok: true, results: [{ id: 1, value: 7 }], snapshot: { stamp: 3, unchanged: true, matches: {} }, syncErr: null, log: ["omanotes-db: migrated 0 -> 5"] })
  assert.deepEqual(Db.reply(0, false, results + "\n", ""), { ok: true, results: [{ id: 1, value: 7 }], snapshot: null, syncErr: null, log: [] },
    "a request with no sync has no line 2")
  assert.deepEqual(Db.reply(0, false, results + "\n{\"stamp\":", ""),
    { ok: true, results: [{ id: 1, value: 7 }], snapshot: null, syncErr: { err: "crash", detail: "unreadable answer" }, log: [] })
  assert.deepEqual(Db.reply(0, false, "{\"results\":[", ""), { ok: false, err: "crash", detail: "unreadable answer", log: [] })
})

test("reply keeps the results of line 1 whenever it is whole: a snapshot that failed (exit 3) or a process that died after it", () => {
  const head = "{\"results\":[{\"id\":4,\"value\":9}]}\n"
  assert.deepEqual(Db.reply(3, false, head + "{\"stamp\":1,\"items\":[", "{\"syncErr\":{\"err\":\"response_too_large\",\"detail\":\"the snapshot is over 64 MiB\"}}\n"),
    { ok: true, results: [{ id: 4, value: 9 }], snapshot: null, syncErr: { err: "response_too_large", detail: "the snapshot is over 64 MiB" }, log: [] })
  assert.deepEqual(Db.reply(9, true, head + "{\"stamp\"", ""),
    { ok: true, results: [{ id: 4, value: 9 }], snapshot: null, syncErr: { err: "crash", detail: "signal 9" }, log: [] })
  assert.deepEqual(Db.reply(139, false, head, "Segmentation fault\n"),
    { ok: true, results: [{ id: 4, value: 9 }], snapshot: null, syncErr: { err: "crash", detail: "exit 139" }, log: ["Segmentation fault"] })
})

test("reply reads 1, 64 and 70 with no line 1 as the last line of stderr, and anything else as a crash", () => {
  for (const code of [1, 64, 70]) {
    assert.deepEqual(Db.reply(code, false, "", "omanotes-db: a line\n{\"err\":\"busy\",\"detail\":\"database is locked\"}\n"),
      { ok: false, err: "busy", detail: "database is locked", log: ["omanotes-db: a line"] })
  }
  assert.deepEqual(Db.reply(1, false, "", "not json\n"), { ok: false, err: "crash", detail: "exit 1", log: ["not json"] })
  assert.deepEqual(Db.reply(3, false, "", ""), { ok: false, err: "crash", detail: "exit 3", log: [] })
  assert.deepEqual(Db.reply(1, true, "", "{\"err\":\"busy\",\"detail\":\"x\"}"), { ok: false, err: "crash", detail: "signal 1", log: ["{\"err\":\"busy\",\"detail\":\"x\"}"] },
    "SIGHUP is exit code 1 with a crash status")
})

test("errorText keeps the words the toasts compare, SQLite's own words and the path of a missing binary", () => {
  assert.equal(Db.errorText({ err: "not_found", detail: "no such row" }), "item not found")
  assert.equal(Db.errorText({ err: "busy", detail: "database is locked" }), "database is locked")
  assert.equal(Db.errorText({ err: "io", detail: "attempt to write a readonly database" }), "attempt to write a readonly database")
  assert.equal(Db.errorText({ err: "refused", detail: "CHECK constraint failed: length(label) <= 40" }), "CHECK constraint failed: length(label) <= 40")
  assert.equal(Db.errorText({ err: "protocol", detail: "the caller speaks another protocol" }), "Omanotes was updated. Run omarchy restart shell to finish")
  assert.equal(Db.errorText({ err: "no_binary", detail: "/p/bin/omanotes-db.riscv64" }), "cannot run the database helper /p/bin/omanotes-db.riscv64")
  assert.equal(Db.errorText({ err: "something_new", detail: "" }), "database error: something_new")
  assert.equal(Db.errorText({ err: "response_too_large", detail: "the snapshot is over 64 MiB" }), "the notes are over 64 MiB, too large to read",
    "a snapshot too large to read is not a text too large to save")
})

test("every failure the binary names, and the two the Store adds, has words", () => {
  const version = JSON.parse(exec([String(Db.PROTOCOL), "version"]).stdout)
  for (const code of [...version.errors, "crash", "no_binary"]) {
    assert.ok(code in Db.ERROR_TEXT, code)
    assert.notEqual(Db.errorText({ err: code, detail: "detail" }), "", code)
  }
})

test("a failed write answers its own code, and errorText turns it into the toast", (t) => {
  const path = newDb(t)
  assert.equal(Db.errorText(run(path, "item.delete", { id: 42 })), "item not found")
  assert.equal(Db.errorText(run(path, "settings.set", { values: { volume: 1 } }, { by: "service" })), "not allowed from here")
  assert.equal(Db.parseSettings(sync(path).settings).settings.volume, 100)
})
