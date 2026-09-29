// Every write of the binary leaves the tables the SQL of before it left, frozen
// in test/fixtures/parity/writes.json: the old builders ran once on the seed
// rows with the clock at T0, and after each step every table and
// sqlite_sequence must equal the frozen ones, and the binary must say found or
// not_found where the old SQL printed changes().
import test from "node:test"
import assert from "node:assert/strict"
import { Db, T0, call, cli, fixture, fold, rows, seeded, tablesAre, write } from "./lib/bin-fixture.mjs"

const W = fixture("writes.json")

// The cells the JS will send for a settings patch: the column of each key and
// the value settingValue gives it (a bool as 0/1).
function settingsCells(patch) {
  const cells = {}
  for (const key of Object.keys(patch)) {
    const v = patch[key]
    cells[Db.SETTINGS[key].column] = typeof v === "boolean" ? (v ? 1 : 0) : v
  }
  return cells
}

// The cells the JS will send for an alarm record, as alarmValues made them.
function alarmCells(r) {
  return {
    hour: r.hour, minute: r.minute, label: r.label || "", days: Db.daysMask(r.days), enabled: r.enabled ? 1 : 0,
    snooze_minutes: r.snoozeMinutes, ring_minutes: r.ringMinutes, snoozed_until_ms: r.snoozedUntil,
    last_fired_at_ms: r.lastFiredAt, armed_at_ms: r.armedAt, auto_snoozes: r.autoSnoozes
  }
}

// The seed rows, migrated by the binary, as the old migrations left them.
function start(t, frozen) {
  const path = seeded(t)
  tablesAre(path, frozen, "the start")
  return path
}

// The labels of `steps` are the frozen ones, in order, so no case is dropped on either side.
function sameCases(steps, frozen) {
  assert.deepEqual(steps.map((s) => s[0]), frozen.map((f) => f.label), "the cases are the frozen ones")
}

// One write through the binary, then every table against the frozen step.
function step(path, frozen, op, args, { by = "widget", at = T0 } = {}) {
  const res = call(path, { writes: [write(op, args, { by, at })] }).results[0]
  tablesAre(path, frozen.tables, frozen.label)
  return res
}

// The id the old SQL printed for an insert, or its changes() as found or not_found.
function sameResult(res, frozen) {
  if ("id" in frozen.result) {
    assert.equal(res.value, frozen.result.id, `${frozen.label}: the new id`)
    return
  }
  assert.equal(res.err === undefined, frozen.result.found, `${frozen.label}: ${JSON.stringify(res)}`)
  if (!frozen.result.found) assert.equal(res.err, "not_found", frozen.label)
}

test("item writes leave the tables the old SQL leaves, and not_found where it printed 0 changes", (t) => {
  const path = start(t, W.items.start)
  const steps = [
    ["add a note with a body", "item.add", { type: "note", title: "Ação O'Brien", body: "line1\nline2" }],
    ["add a todo without a body", "item.add", { type: "todo", title: "Plain", body: "" }],
    ["add with quotes, a backslash and wildcards", "item.add", { type: "note", title: "It's \"x\" \\ %_", body: "b'" }],
    ["add with a body left out", "item.add", { type: "note", title: "No body" }],
    ["complete a todo", "item.status", { id: 2, status: 1 }],
    ["complete it again", "item.status", { id: 2, status: 1 }],
    ["reopen a read note", "item.status", { id: 4, status: 0 }],
    ["edit", "item.update", { id: 1, title: "Ideas v2", body: "new body" }],
    ["edit only the case (the trigger folds again)", "item.update", { id: 1, title: "IDEAS V2", body: "new body" }],
    ["edit to an empty body", "item.update", { id: 3, title: "Reply", body: "" }],
    ["convert", "item.convert", { id: 3 }],
    ["move after, in the second block", "item.move", { id: 5, anchorId: 2, after: true }],
    ["move before, in the first block", "item.move", { id: 3, anchorId: 1, after: false }],
    ["move across blocks", "item.move", { id: 1, anchorId: 2, after: true }],
    ["move onto itself", "item.move", { id: 1, anchorId: 1, after: true }],
    ["delete", "item.delete", { id: 5 }],
    ["complete a missing id", "item.status", { id: 999, status: 1 }],
    ["edit a missing id", "item.update", { id: 999, title: "x", body: "" }],
    ["convert a missing id", "item.convert", { id: 999 }],
    ["delete a missing id", "item.delete", { id: 999 }],
    ["move to a missing anchor", "item.move", { id: 1, anchorId: 999, after: true }]
  ]
  sameCases(steps, W.items.steps)
  let moved = 0
  let missing = 0
  steps.forEach(([, op, args], i) => {
    const frozen = W.items.steps[i]
    const res = step(path, frozen, op, args)
    sameResult(res, frozen)
    if (res.err === "not_found") missing++
    if (op === "item.move" && res.err === undefined) moved++
  })
  assert.ok(moved >= 2, "at least two moves moved a row")
  assert.ok(missing >= 6, "the missing ids and the move onto itself were not found")
  assert.ok(rows(path, "SELECT count(*) AS n FROM history")[0].n > 3, "the writes logged history")
})

test("history and settings writes leave the tables the old SQL leaves", (t) => {
  const path = start(t, W.items.start)
  // The old prune read SQLite's clock; the binary takes the caller's, and the frozen run had W.now.
  const now = W.now
  const steps = [
    ["delete one history entry", "history.delete", { id: 2 }, T0],
    ["delete a missing history entry", "history.delete", { id: 999 }, T0],
    ["prune 30 days", "history.prune", { days: 30 }, now],
    ["one setting", "settings.set", { values: settingsCells({ volume: 55 }) }, T0],
    ["several settings, a quote in the text", "settings.set", { values: settingsCells({ soundOn: false, sound: "x'y", soundFile: "/tmp/a b.oga", snoozeMinutes: 12 }) }, T0],
    ["Keep 90 days", "settings.set", { values: settingsCells({ historyDays: 90 }) }, now],
    ["clear history", "history.clear", {}, T0]
  ]
  sameCases(steps, W.historyAndSettings.steps)
  steps.forEach(([label, op, args, at], i) => {
    const res = step(path, W.historyAndSettings.steps[i], op, args, { at })
    assert.equal(res.err, undefined, `${label}: ${JSON.stringify(res)}`)
  })
})

test("a shorter Keep prunes in the same transaction as the setting, as setSettingsSql did", (t) => {
  const path = start(t, W.items.start)
  const now = W.now
  cli(path, `INSERT INTO history (type, title, action, ts) VALUES ('note', 'recent', 'added', ${now - 86400}), ('note', 'old', 'added', ${now - 40 * 86400})`)
  step(path, { label: "Keep 30 days", tables: W.shorterKeep.tables }, "settings.set", { values: settingsCells({ historyDays: 30 }) }, { at: now })
  assert.deepEqual(rows(path, "SELECT title FROM history").map((r) => r.title), ["recent"])
})

test("a setting out of range, an unknown column or an empty patch changes nothing", (t) => {
  const path = start(t, W.settingsStart.tables)
  for (const [label, values, code] of [
    ["volume 101 (the CHECK)", { volume: 101 }, "refused"],
    ["Keep 7 days (the CHECK)", { history_days: 7 }, "refused"],
    ["a text in sound_on (the CHECK)", { sound_on: "yes" }, "refused"],
    ["an unknown column", { nope: 1 }, "bad_request"],
    ["the id column", { id: 2 }, "bad_request"],
    ["a fraction", { volume: 5.5 }, "bad_request"],
    ["a boolean", { sound_on: true }, "bad_request"],
    ["no column", {}, "bad_request"]
  ]) {
    const res = call(path, { writes: [write("settings.set", { values })] }).results[0]
    assert.equal(res.err, code, `${label}: ${JSON.stringify(res)}`)
    tablesAre(path, W.settingsStart.tables, label)
  }
})

const ALARM = { hour: 7, minute: 30, label: "Wake", days: [1, 2, 3], enabled: true, snoozeMinutes: 9, ringMinutes: 5, snoozedUntil: 0, lastFiredAt: 0, armedAt: 1700000000000, autoSnoozes: 0 }

test("alarm writes leave the tables the old SQL leaves, and only the service may send them", (t) => {
  const path = start(t, W.items.start)
  const service = { by: "service" }
  const frozen = W.alarms.steps
  const saved = { ...ALARM, id: frozen[0].result.id, hour: 8, days: [0, 6, 6, 9, 2.5], label: "Café", enabled: false, snoozedUntil: 1700000600000 }
  const steps = [
    ["insert", "alarm.insert", { alarm: alarmCells(ALARM) }],
    ["save", "alarm.save", { id: saved.id, alarm: alarmCells(saved) }],
    ["save a missing alarm", "alarm.save", { id: 999, alarm: alarmCells(saved) }],
    ["insert a second", "alarm.insert", { alarm: alarmCells({ ...ALARM, minute: 45 }) }],
    ["delete", "alarm.delete", { id: saved.id }],
    ["delete a missing alarm", "alarm.delete", { id: 999 }]
  ]
  sameCases(steps, frozen)
  const results = steps.map(([, op, args], i) => {
    const res = step(path, frozen[i], op, args, service)
    sameResult(res, frozen[i])
    return res
  })
  assert.deepEqual(results.map((r) => r.err), [undefined, undefined, "not_found", undefined, undefined, "not_found"])
  const last = frozen[frozen.length - 1].tables

  for (const [label, record, code] of [
    ["hour 24", { ...alarmCells(ALARM), hour: 24 }, "refused"],
    ["a label of 41 characters", { ...alarmCells(ALARM), label: "x".repeat(41) }, "refused"],
    ["snooze 0", { ...alarmCells(ALARM), snooze_minutes: 0 }, "refused"],
    ["a column left out", Object.fromEntries(Object.entries(alarmCells(ALARM)).filter(([k]) => k !== "armed_at_ms")), "bad_request"],
    ["an unknown column", { ...alarmCells(ALARM), ring: 1 }, "bad_request"],
    ["the id inside the record", { ...alarmCells(ALARM), id: 1 }, "bad_request"]
  ]) {
    const res = call(path, { writes: [write("alarm.insert", { alarm: record }, service)] }).results[0]
    assert.equal(res.err, code, `${label}: ${JSON.stringify(res)}`)
    tablesAre(path, last, label)
  }

  // ADR-0015 and ADR-0016 are a lookup in the binary: a widget cannot write alarms, the service cannot write the rest.
  const widget = call(path, { writes: [write("alarm.insert", { alarm: alarmCells(ALARM) }), write("alarm.save", { id: 1, alarm: alarmCells(ALARM) }, { id: 2 }), write("alarm.delete", { id: 1 }, { id: 3 })] })
  assert.deepEqual(widget.results.map((r) => r.err), ["forbidden", "forbidden", "forbidden"])
  const fromService = call(path, { writes: [
    write("settings.set", { values: { volume: 1 } }, { by: "service" }),
    write("item.add", { type: "note", title: "x" }, { by: "service", id: 2 }),
    write("history.clear", {}, { by: "service", id: 3 }),
    write("backup", { day: "2026-09-28" }, { by: "service", id: 4 })
  ] })
  assert.deepEqual(fromService.results.map((r) => r.err), ["forbidden", "forbidden", "forbidden", "forbidden"])
  tablesAre(path, last, "the forbidden writes changed nothing")
})

test("a search matches the ids the old listSql matched, in the same order", (t) => {
  const path = start(t, W.items.start)
  cli(path, "INSERT INTO items (type, title, body, status, created_at, updated_at, position) VALUES ('note', 'Café com Leite', 'AÇÃO urgente', 0, 1, 1, 1), ('todo', 'ÑANDÚ 100%', 'a_b', 0, 1, 1, 2), ('note', 'Straße Ωmega', NULL, 1, 1, 1, 1), ('todo', 'back\\slash', 'x', 0, 1, 1, 3)")
  const queries = ["cafe", "CAFÉ", "acao", "100%", "a_b", "nandu", "straße", "ω", "\\", "_", "%", "zzz", "e"]
  const filters = ["all", "note", "todo", "bogus"]
  const frozen = W.search.views
  assert.deepEqual(frozen.map((v) => [v.query, v.filter]), queries.flatMap((q) => filters.map((f) => [q, f])), "the searches are the frozen ones")
  // The caller trims before it sends, as listSql trimmed.
  const views = frozen.map((v, i) => ({ key: "v" + i, filter: v.filter, query: v.query.trim() }))
  const snap = call(path, { sync: { since: -1, views } }).snapshot
  views.forEach((view, i) => assert.deepEqual(snap.matches[view.key], frozen[i].ids, `${JSON.stringify(view.query)} in ${view.filter}`))
  assert.ok(frozen.some((v) => v.ids.length > 1), "some search matched more than one item")
  assert.ok(frozen.some((v) => v.ids.length === 0), "some search matched nothing")
  // An empty query is every item of the filter, in list order.
  const empty = call(path, { sync: { since: -1, views: [{ key: "all", filter: "all", query: "" }, { key: "todo", filter: "todo", query: "" }] } }).snapshot
  assert.deepEqual(empty.matches.all, W.search.empty.all)
  assert.deepEqual(empty.matches.todo, W.search.empty.todo)
})

test("the text the binary folds is the text searchText folds and the text the triggers fold", (t) => {
  const path = seeded(t)
  // Every unit of the fold table, a surrogate pair, and some text the table leaves alone.
  let every = ""
  for (let u = 0; u < 0x10000; u++) {
    const c = String.fromCharCode(u)
    if (u < 0xd800 || u > 0xdfff) if (fold(c) !== c) every += c
  }
  assert.equal(every.length, 2299, "every unit of the fold table")
  const title = every.slice(0, 1200) + " 😀 abc"
  const body = every.slice(1200) + " Ωmega"
  const added = call(path, { writes: [write("item.add", { type: "note", title, body })] }).results[0]
  // The same text through the CLI, which leaves the copy NULL, so items_search_insert folds it.
  cli(path, `INSERT INTO items (type, title, body, status, created_at, updated_at) VALUES ('note', '${title.replace(/'/g, "''")}', '${body.replace(/'/g, "''")}', 0, 1, 1)`)
  const [bin, trigger] = rows(path, `SELECT search_title, search_body FROM items WHERE id >= ${added.value} ORDER BY id`)
  assert.equal(bin.search_title, fold(title))
  assert.equal(bin.search_body, fold(body))
  assert.deepEqual(trigger, bin)
})
