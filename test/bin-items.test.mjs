// What the list, the search, the counts and the item writes do, through the
// binary the plugin runs and the snapshot it reads (ADR-0005, ADR-0006,
// ADR-0012, ADR-0014). The CLI edits the file by hand and reads it back.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { Db, T0, cli, newDb, rows, run, seeded, sync, v0Db } from "./lib/bin-fixture.mjs"

function ids(list) {
  return list.map((r) => r.id)
}

// The list of a filter, as a view shows it from the snapshot.
function order(path, filter = "all") {
  return ids(Db.typeRows(sync(path).items, filter))
}

// The ids a search matched, in list order.
function searchIds(path, filter, query) {
  return sync(path, -1, [{ key: "v", filter, query: query.trim() }]).matches.v
}

function positions(path, status) {
  return rows(path, "SELECT id, position FROM items WHERE status = " + status + " ORDER BY position")
}

function item(path, id) {
  return rows(path, "SELECT * FROM items WHERE id = " + id)[0]
}

function history(path) {
  return rows(path, "SELECT id, type, title, action, ts FROM history ORDER BY id")
}

function tables(path) {
  return { items: rows(path, "SELECT * FROM items ORDER BY id"), history: history(path) }
}

const found = (result) => result.err === undefined

test("the list: status 0 (unread or pending) first, then each block in its order", (t) => {
  assert.deepEqual(order(seeded(t)), [2, 1, 3, 5, 4])
})

test("the migration numbers each block in the order the list showed, the newest id first on a tie", (t) => {
  const path = v0Db(t)
  cli(path, "INSERT INTO items (id, type, title, body, status, created_at, updated_at) VALUES"
    + " (6, 'note', 'Same second as 2', NULL, 0, " + (T0 - 720) + ", " + (T0 - 720) + "),"
    + " (7, 'todo', 'Same second as 4', NULL, 1, " + (T0 - 90000) + ", " + (T0 - 90000) + ")")
  const shown = ids(rows(path, "SELECT id FROM items ORDER BY status ASC, updated_at DESC, id DESC"))
  assert.deepEqual(order(path), shown)
  assert.deepEqual(order(path), [6, 2, 1, 3, 5, 7, 4])
  assert.deepEqual(positions(path, 0), [{ id: 6, position: 1 }, { id: 2, position: 2 }, { id: 1, position: 3 }, { id: 3, position: 4 }])
  assert.deepEqual(positions(path, 1), [{ id: 5, position: 1 }, { id: 7, position: 2 }, { id: 4, position: 3 }])
})

test("an add goes to the top of the first block, whatever the other items' times", (t) => {
  const path = seeded(t)
  cli(path, "UPDATE items SET updated_at = " + (T0 + 100) + " WHERE id = 2")
  const id = run(path, "item.add", { type: "note", title: "Buy milk", body: "" }).value
  assert.deepEqual(order(path), [id, 2, 1, 3, 5, 4])
  const other = run(path, "item.add", { type: "todo", title: "Call the bank", body: "" }).value
  assert.deepEqual(order(path), [other, id, 2, 1, 3, 5, 4])
})

test("an add goes above the items reopened before it", (t) => {
  const path = seeded(t)
  run(path, "item.status", { id: 5, status: 0 })
  run(path, "item.status", { id: 4, status: 0 })
  const id = run(path, "item.add", { type: "note", title: "Buy milk", body: "" }).value
  assert.deepEqual(order(path), [id, 4, 5, 2, 1, 3])
})

test("a read or completed item goes to the top of the second block, a reopened one to the top of the first", (t) => {
  const path = seeded(t)
  run(path, "item.move", { id: 4, anchorId: 5, after: false })
  assert.deepEqual(order(path), [2, 1, 3, 4, 5])
  run(path, "item.status", { id: 3, status: 1 })
  assert.deepEqual(order(path), [2, 1, 3, 4, 5])
  assert.deepEqual(ids(positions(path, 1)), [3, 4, 5])
  run(path, "item.status", { id: 5, status: 0 })
  assert.deepEqual(order(path), [5, 2, 1, 3, 4])
  run(path, "item.status", { id: 1, status: 1 })
  assert.deepEqual(order(path), [5, 2, 1, 3, 4])
  assert.deepEqual(ids(positions(path, 1)), [1, 3, 4])
})

test("setting the status an item already has leaves it in place and records nothing", (t) => {
  const path = seeded(t)
  run(path, "item.move", { id: 3, anchorId: 2, after: false })
  const before = tables(path)
  assert.ok(found(run(path, "item.status", { id: 1, status: 0 })))
  assert.ok(found(run(path, "item.status", { id: 4, status: 1 })))
  assert.deepEqual(order(path), [3, 2, 1, 5, 4])
  assert.deepEqual(tables(path), before)
})

test("an edit and a convert leave an item where it is", (t) => {
  const path = seeded(t)
  const before = rows(path, "SELECT id, position FROM items ORDER BY id")
  run(path, "item.update", { id: 3, title: "Answer the review", body: "by Friday" })
  run(path, "item.convert", { id: 3 })
  run(path, "item.update", { id: 4, title: "Buy tea", body: "" })
  run(path, "item.convert", { id: 4 })
  assert.deepEqual(order(path), [2, 1, 3, 5, 4])
  assert.deepEqual(rows(path, "SELECT id, position FROM items ORDER BY id"), before)
})

test("a move puts an item just before or just after another of its block", (t) => {
  const path = seeded(t)
  assert.ok(found(run(path, "item.move", { id: 3, anchorId: 2, after: false })))
  assert.deepEqual(order(path), [3, 2, 1, 5, 4])
  run(path, "item.move", { id: 3, anchorId: 1, after: true })
  assert.deepEqual(order(path), [2, 1, 3, 5, 4])
  run(path, "item.move", { id: 2, anchorId: 3, after: true })
  assert.deepEqual(order(path), [1, 3, 2, 5, 4])
  run(path, "item.move", { id: 4, anchorId: 5, after: false })
  assert.deepEqual(order(path), [1, 3, 2, 4, 5])
})

test("a move renumbers only the item's block and changes nothing else", (t) => {
  const path = seeded(t)
  const before = tables(path)
  run(path, "item.move", { id: 3, anchorId: 2, after: false })
  assert.deepEqual(positions(path, 0), [{ id: 3, position: 1 }, { id: 2, position: 2 }, { id: 1, position: 3 }])
  const after = tables(path)
  assert.deepEqual(after.history, before.history)
  const strip = (items) => items.map(({ position, ...rest }) => rest)
  assert.deepEqual(strip(after.items), strip(before.items))
  assert.deepEqual(after.items.filter((i) => i.status === 1), before.items.filter((i) => i.status === 1))
})

test("a move across the two blocks, onto the item itself or with a missing id writes nothing and is not_found", (t) => {
  const path = seeded(t)
  const before = tables(path)
  for (const args of [{ id: 5, anchorId: 2, after: false }, { id: 2, anchorId: 4, after: true }, { id: 2, anchorId: 2, after: false },
    { id: 99, anchorId: 2, after: false }, { id: 2, anchorId: 99, after: true }]) {
    assert.equal(run(path, "item.move", args).err, "not_found", JSON.stringify(args))
    assert.deepEqual(tables(path), before)
  }
})

test("a move among the notes keeps the todos where they were", (t) => {
  const path = seeded(t)
  const note = run(path, "item.add", { type: "note", title: "Buy milk", body: "" }).value
  assert.deepEqual(order(path), [note, 2, 1, 3, 5, 4])
  assert.deepEqual(order(path, "note"), [note, 1, 4])
  run(path, "item.move", { id: 1, anchorId: note, after: false })
  assert.deepEqual(order(path, "note"), [1, note, 4])
  assert.deepEqual(order(path), [1, note, 2, 3, 5, 4])
  run(path, "item.move", { id: 1, anchorId: note, after: true })
  assert.deepEqual(order(path), [note, 1, 2, 3, 5, 4])
  run(path, "item.move", { id: note, anchorId: 1, after: true })
  assert.deepEqual(order(path), [1, note, 2, 3, 5, 4])
  assert.deepEqual(order(path, "todo"), [2, 3, 5])
})

test("the type filter keeps the list order, and an unknown filter lists every item", (t) => {
  const path = seeded(t)
  assert.deepEqual(order(path, "todo"), [2, 3, 5])
  assert.deepEqual(order(path, "note"), [1, 4])
  assert.deepEqual(order(path, "bogus"), [2, 1, 3, 5, 4])
  assert.deepEqual(sync(path, -1, [{ key: "v", filter: "note' OR 1=1 --", query: "" }]).matches.v, [2, 1, 3, 5, 4])
})

test("a search matches the title or the body and ignores ASCII case", (t) => {
  const path = seeded(t)
  assert.deepEqual(searchIds(path, "all", "DOMAIN"), [2])
  assert.deepEqual(searchIds(path, "all", "grind"), [4])
  assert.deepEqual(searchIds(path, "note", "domain"), [])
})

// Every spelling of a word finds the item, whatever its case and accents, and
// an accent typed as a separate combining mark counts the same.
function assertAccentedSearch(path, titleId, bodyId) {
  for (const query of ["CAFÉ", "cafe", "Cafe", "café", "CAFE", "café"]) {
    assert.deepEqual(searchIds(path, "all", query), [titleId], query)
  }
  for (const query of ["AÇÃO", "ação", "acao", "Acao", "PÃO", "pao"]) {
    assert.deepEqual(searchIds(path, "all", query), [bodyId], query)
  }
  assert.deepEqual(searchIds(path, "todo", "cafe"), [])
  assert.deepEqual(searchIds(path, "all", "cafes"), [])
}

test("a search ignores case and accents in items from before the migration", (t) => {
  const path = v0Db(t, { withSeed: false })
  cli(path, "INSERT INTO items (id, type, title, body, status, created_at, updated_at) VALUES"
    + " (1, 'note', 'Café', NULL, 0, " + T0 + ", " + T0 + "),"
    + " (2, 'todo', 'Padaria', 'Revisar a AÇÃO do pão', 0, " + (T0 - 1) + ", " + (T0 - 1) + ")")
  assertAccentedSearch(path, 1, 2)
})

test("a search ignores case and accents in items added or edited after it", (t) => {
  const path = seeded(t)
  const cafe = run(path, "item.add", { type: "note", title: "Café", body: "" }).value
  run(path, "item.update", { id: 2, title: "Padaria", body: "Revisar a AÇÃO do pão" })
  assertAccentedSearch(path, cafe, 2)
  run(path, "item.update", { id: cafe, title: "Chá", body: "" })
  assert.deepEqual(searchIds(path, "all", "cafe"), [])
  assert.deepEqual(searchIds(path, "all", "CHA"), [cafe])
})

test("a search finds items inserted or edited with sqlite3 after the migration", (t) => {
  const path = newDb(t)
  run(path, "item.add", { type: "note", title: "Buy milk", body: "" })
  cli(path, "INSERT INTO items (type, title, body, status, created_at, updated_at)"
    + " VALUES ('todo', 'Renew the domain', 'Pagar a AÇÃO', 0, " + T0 + ", " + T0 + ")")
  cli(path, "UPDATE items SET title = 'Call the bank' WHERE id = 1")
  assert.deepEqual(searchIds(path, "all", "domain"), [2])
  assert.deepEqual(searchIds(path, "all", "acao"), [2])
  assert.deepEqual(searchIds(path, "all", "CALL"), [1])
  assert.deepEqual(searchIds(path, "all", "milk"), [])
  cli(path, "UPDATE items SET body = 'Due day 30' WHERE id = 2")
  assert.deepEqual(searchIds(path, "all", "acao"), [])
  assert.deepEqual(searchIds(path, "all", "DUE"), [2])
})

test("a quote and the LIKE wildcards in a search are matched literally", (t) => {
  const path = newDb(t)
  for (const title of ["it's 100% done", "it's 1000 done", "a\\b"]) run(path, "item.add", { type: "note", title, body: "" })
  assert.deepEqual(searchIds(path, "all", "it's 100%"), [1])
  assert.deepEqual(searchIds(path, "all", "_"), [])
  assert.deepEqual(searchIds(path, "all", "a\\b"), [3])
})

test("the counts: zero on an empty file; unread notes, pending todos, totals per type and the oldest entry", (t) => {
  assert.deepEqual(Db.parseCounts(sync(newDb(t)).counts), { unreadNotes: 0, pendingTodos: 0, notes: 0, todos: 0, history: 0, oldestHistory: 0 })
  assert.deepEqual(Db.parseCounts(sync(seeded(t)).counts),
    { unreadNotes: 1, pendingTodos: 2, notes: 2, todos: 3, history: 3, oldestHistory: T0 - 100000 })
})

test("an add stores the item, answers its id and logs it as added", (t) => {
  const path = seeded(t)
  assert.equal(run(path, "item.add", { type: "todo", title: "Jane's list", body: "milk, 'eggs'" }).value, 6)
  assert.deepEqual(item(path, 6), {
    id: 6, type: "todo", title: "Jane's list", body: "milk, 'eggs'", status: 0, position: 0, created_at: T0, updated_at: T0,
    search_title: "jane's list", search_body: "milk, 'eggs'"
  })
  assert.deepEqual(history(path).at(-1), { id: 4, type: "todo", title: "Jane's list", action: "added", ts: T0 })
})

test("an add stores an empty body as NULL, and refuses a type that is not note or todo", (t) => {
  const path = newDb(t)
  const id = run(path, "item.add", { type: "note", title: "Buy milk", body: "" }).value
  assert.equal(item(path, id).body, null)
  assert.equal(item(path, id).search_body, null)
  assert.equal(run(path, "item.add", { type: "bogus", title: "x", body: "" }).err, "bad_request")
})

test("completing a todo, and marking a read note unread, which logs it as reopened", (t) => {
  const path = seeded(t)
  run(path, "item.status", { id: 2, status: 1 })
  assert.equal(item(path, 2).status, 1)
  assert.equal(item(path, 2).updated_at, T0)
  assert.deepEqual(history(path).at(-1), { id: 4, type: "todo", title: "Renew the domain", action: "completed", ts: T0 })
  run(path, "item.status", { id: 4, status: 0 })
  assert.equal(item(path, 4).status, 0)
  assert.deepEqual(history(path).at(-1), { id: 5, type: "note", title: "Buy coffee", action: "reopened", ts: T0 })
})

for (const [op, args] of [
  ["item.status", (id) => ({ id, status: 1 })],
  ["item.update", (id) => ({ id, title: "Renew the car", body: "x" })],
  ["item.convert", (id) => ({ id })],
  ["item.delete", (id) => ({ id })]
]) {
  test(op + " answers not_found for a missing id and records nothing", (t) => {
    const path = seeded(t)
    const before = tables(path)
    assert.equal(run(path, op, args(99)).err, "not_found")
    assert.deepEqual(tables(path), before)
    assert.ok(found(run(path, op, args(2))))
    assert.notDeepEqual(tables(path), before)
  })
}

test("an edit: new title and body, logged with the new title; an emptied body is NULL", (t) => {
  const path = seeded(t)
  run(path, "item.update", { id: 3, title: "Answer the review", body: "by Friday" })
  const row = item(path, 3)
  assert.deepEqual([row.title, row.body, row.updated_at, row.created_at], ["Answer the review", "by Friday", T0, T0 - 10800])
  assert.deepEqual(history(path).at(-1), { id: 4, type: "todo", title: "Answer the review", action: "edited", ts: T0 })
  run(path, "item.update", { id: 1, title: "Ideas for the panel", body: "" })
  assert.equal(item(path, 1).body, null)
  assert.equal(item(path, 1).search_body, null)
})

test("a delete removes the item and logs its title", (t) => {
  const path = seeded(t)
  run(path, "item.delete", { id: 4 })
  assert.equal(item(path, 4), undefined)
  assert.deepEqual(order(path), [2, 1, 3, 5])
  assert.deepEqual(history(path).at(-1), { id: 4, type: "note", title: "Buy coffee", action: "deleted", ts: T0 })
})

test("a convert flips the type, keeps the status and logs the new type", (t) => {
  const path = seeded(t)
  run(path, "item.convert", { id: 4 })
  assert.deepEqual([item(path, 4).type, item(path, 4).status, item(path, 4).updated_at], ["todo", 1, T0])
  assert.deepEqual(history(path).at(-1), { id: 4, type: "todo", title: "Buy coffee", action: "converted", ts: T0 })
  run(path, "item.convert", { id: 4 })
  assert.equal(item(path, 4).type, "note")
})

test("an id that is not a whole number is bad_request and writes nothing", (t) => {
  const path = seeded(t)
  const before = tables(path)
  for (const id of ["2", 1.5, -1, true, null]) {
    assert.equal(run(path, "item.delete", { id }).err, "bad_request", JSON.stringify(id))
  }
  assert.deepEqual(tables(path), before)
})

for (const [op, args, failOn] of [
  ["item.add", { type: "todo", title: "Renew the car", body: "" }, "INSERT ON history"],
  ["item.status", { id: 2, status: 1 }, "UPDATE ON items"],
  ["item.update", { id: 2, title: "Renew the car", body: "x" }, "INSERT ON history"],
  ["item.convert", { id: 2 }, "INSERT ON history"],
  ["item.delete", { id: 2 }, "DELETE ON items"]
]) {
  test(op + ": a failing second change writes nothing", (t) => {
    const path = seeded(t)
    cli(path, "CREATE TRIGGER fail_second BEFORE " + failOn + " BEGIN SELECT RAISE(ABORT, 'forced'); END")
    const before = tables(path)
    const result = run(path, op, args)
    assert.equal(result.err, "refused")
    assert.match(result.detail, /forced/)
    assert.deepEqual(tables(path), before)
  })
}

test("the history: newest first, the newest 500 rows, and a count of every entry", (t) => {
  const path = seeded(t)
  assert.deepEqual(ids(sync(path).history), [1, 2, 3])
  cli(path, "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 600)"
    + " INSERT INTO history (type, title, action, ts) SELECT 'note', 'bulk', 'added', " + T0 + " + i FROM n")
  const snap = sync(path)
  assert.equal(snap.history.length, 500)
  assert.equal(snap.history[0].ts, T0 + 600)
  assert.equal(snap.history[499].ts, T0 + 101)
  assert.equal(Db.parseCounts(snap.counts).history, 603)
})

test("deleting one history entry removes it, clearing removes all of them, and the items stay", (t) => {
  const path = seeded(t)
  run(path, "history.delete", { id: 2 })
  assert.deepEqual(ids(history(path)), [1, 3])
  run(path, "history.clear", {})
  assert.deepEqual(history(path), [])
  assert.equal(sync(path).items.length, 5)
})

test("the plugin writes no SQL of its own: no data/ file but the binary names a table", () => {
  for (const file of ["Db.js", "Store.qml", "ItemsDb.qml", "AlarmsDb.qml", "Lane.qml"]) {
    const text = readFileSync(new URL("../data/" + file, import.meta.url), "utf8")
    assert.doesNotMatch(text, /\b(SELECT|INSERT|UPDATE|DELETE)\b.*\b(FROM|INTO|SET)\b/, file)
  }
})
