// Every write of the binary leaves the tables the SQL of before it (test/lib/legacy-db.js) leaves.
// Two copies of one database: the old builders run on one through the CLI with
// the clock frozen at T0, the binary runs the same op on the other with at = T0,
// and after each step every table and sqlite_sequence must be equal, and the
// binary must say found or not_found where the old SQL printed changes().
import test from "node:test"
import assert from "node:assert/strict"
import { Db, Legacy, T0, atT0, call, cli, pair, rows, sameTables, write } from "./lib/bin-fixture.mjs"

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

// The old builder through the CLI, the new op through the binary, then every table compared.
function both(p, label, oldSql, op, args, { by = "widget", at = T0 } = {}) {
  const out = atT0(() => cli(p.old, oldSql()))
  const res = call(p.bin, { writes: [write(op, args, { by, at })] }).results[0]
  sameTables(p.old, p.bin, label)
  return { out, res }
}

test("item writes leave the tables the old SQL leaves, and not_found where it printed 0 changes", (t) => {
  const p = pair(t)
  let moved = 0
  const steps = [
    ["add a note with a body", () => Legacy.addSql("note", "Ação O'Brien", "line1\nline2"), "item.add", { type: "note", title: "Ação O'Brien", body: "line1\nline2" }],
    ["add a todo without a body", () => Legacy.addSql("todo", "Plain", ""), "item.add", { type: "todo", title: "Plain", body: "" }],
    ["add with quotes, a backslash and wildcards", () => Legacy.addSql("note", "It's \"x\" \\ %_", "b'"), "item.add", { type: "note", title: "It's \"x\" \\ %_", body: "b'" }],
    ["add with a body left out", () => Legacy.addSql("note", "No body", undefined), "item.add", { type: "note", title: "No body" }],
    ["complete a todo", () => Legacy.setStatusSql(2, 1), "item.status", { id: 2, status: 1 }],
    ["complete it again", () => Legacy.setStatusSql(2, 1), "item.status", { id: 2, status: 1 }],
    ["reopen a read note", () => Legacy.setStatusSql(4, 0), "item.status", { id: 4, status: 0 }],
    ["edit", () => Legacy.updateSql(1, "Ideas v2", "new body"), "item.update", { id: 1, title: "Ideas v2", body: "new body" }],
    ["edit only the case (the trigger folds again)", () => Legacy.updateSql(1, "IDEAS V2", "new body"), "item.update", { id: 1, title: "IDEAS V2", body: "new body" }],
    ["edit to an empty body", () => Legacy.updateSql(3, "Reply", ""), "item.update", { id: 3, title: "Reply", body: "" }],
    ["convert", () => Legacy.convertTypeSql(3), "item.convert", { id: 3 }],
    ["move after, in the second block", () => Legacy.moveSql(5, 2, true), "item.move", { id: 5, anchorId: 2, after: true }],
    ["move before, in the first block", () => Legacy.moveSql(3, 1, false), "item.move", { id: 3, anchorId: 1, after: false }],
    ["move across blocks", () => Legacy.moveSql(1, 2, true), "item.move", { id: 1, anchorId: 2, after: true }],
    ["move onto itself", () => Legacy.moveSql(1, 1, true), "item.move", { id: 1, anchorId: 1, after: true }],
    ["delete", () => Legacy.deleteItemSql(5), "item.delete", { id: 5 }],
    ["complete a missing id", () => Legacy.setStatusSql(999, 1), "item.status", { id: 999, status: 1 }],
    ["edit a missing id", () => Legacy.updateSql(999, "x", ""), "item.update", { id: 999, title: "x", body: "" }],
    ["convert a missing id", () => Legacy.convertTypeSql(999), "item.convert", { id: 999 }],
    ["delete a missing id", () => Legacy.deleteItemSql(999), "item.delete", { id: 999 }],
    ["move to a missing anchor", () => Legacy.moveSql(1, 999, true), "item.move", { id: 1, anchorId: 999, after: true }]
  ]
  let missing = 0
  for (const [label, oldSql, op, args] of steps) {
    const { out, res } = both(p, label, oldSql, op, args)
    if (op === "item.add") {
      assert.equal(res.value, Legacy.parseId(out), `${label}: the new id`)
      continue
    }
    const found = Legacy.parseFound(out)
    assert.equal(res.err === undefined, found, `${label}: ${JSON.stringify(res)}`)
    if (!found) {
      assert.equal(res.err, "not_found", label)
      missing++
    }
    if (op === "item.move" && found) moved++
  }
  assert.ok(moved >= 2, "at least two moves moved a row")
  assert.ok(missing >= 6, "the missing ids and the move onto itself were not found")
  assert.ok(rows(p.bin, "SELECT count(*) AS n FROM history")[0].n > 3, "the writes logged history")
})

test("history and settings writes leave the tables the old SQL leaves", (t) => {
  const p = pair(t)
  // The old prune read SQLite's clock; the binary takes the caller's, so both get the real time.
  const now = Math.floor(Date.now() / 1000)
  const steps = [
    ["delete one history entry", () => Legacy.deleteHistorySql(2), "history.delete", { id: 2 }, T0],
    ["delete a missing history entry", () => Legacy.deleteHistorySql(999), "history.delete", { id: 999 }, T0],
    ["prune 30 days", () => Legacy.pruneHistorySql(30), "history.prune", { days: 30 }, now],
    ["one setting", () => Legacy.setSettingsSql({ volume: 55 }), "settings.set", { values: settingsCells({ volume: 55 }) }, T0],
    ["several settings, a quote in the text", () => Legacy.setSettingsSql({ soundOn: false, sound: "x'y", soundFile: "/tmp/a b.oga", snoozeMinutes: 12 }), "settings.set", { values: settingsCells({ soundOn: false, sound: "x'y", soundFile: "/tmp/a b.oga", snoozeMinutes: 12 }) }, T0],
    ["Keep 90 days", () => Legacy.setSettingsSql({ historyDays: 90 }), "settings.set", { values: settingsCells({ historyDays: 90 }) }, now],
    ["clear history", () => Legacy.clearHistorySql(), "history.clear", {}, T0]
  ]
  for (const [label, oldSql, op, args, at] of steps) {
    const { res } = both(p, label, oldSql, op, args, { at })
    assert.equal(res.err, undefined, `${label}: ${JSON.stringify(res)}`)
  }
})

test("a shorter Keep prunes in the same transaction as the setting, as setSettingsSql did", (t) => {
  const p = pair(t)
  const now = Math.floor(Date.now() / 1000)
  cli(p.old, `INSERT INTO history (type, title, action, ts) VALUES ('note', 'recent', 'added', ${now - 86400}), ('note', 'old', 'added', ${now - 40 * 86400})`)
  cli(p.bin, `INSERT INTO history (type, title, action, ts) VALUES ('note', 'recent', 'added', ${now - 86400}), ('note', 'old', 'added', ${now - 40 * 86400})`)
  both(p, "Keep 30 days", () => Legacy.setSettingsSql({ historyDays: 30 }), "settings.set", { values: settingsCells({ historyDays: 30 }) }, { at: now })
  assert.deepEqual(rows(p.bin, "SELECT title FROM history").map((r) => r.title), ["recent"])
})

test("a setting out of range, an unknown column or an empty patch changes nothing", (t) => {
  const p = pair(t)
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
    const res = call(p.bin, { writes: [write("settings.set", { values })] }).results[0]
    assert.equal(res.err, code, `${label}: ${JSON.stringify(res)}`)
    sameTables(p.old, p.bin, label)
  }
})

const ALARM = { hour: 7, minute: 30, label: "Wake", days: [1, 2, 3], enabled: true, snoozeMinutes: 9, ringMinutes: 5, snoozedUntil: 0, lastFiredAt: 0, armedAt: 1700000000000, autoSnoozes: 0 }

test("alarm writes leave the tables the old SQL leaves, and only the service may send them", (t) => {
  const p = pair(t)
  const service = { by: "service" }
  const ins = both(p, "insert", () => Legacy.insertAlarmSql(ALARM), "alarm.insert", { alarm: alarmCells(ALARM) }, service)
  assert.equal(ins.res.value, Legacy.parseId(ins.out))
  const saved = { ...ALARM, id: ins.res.value, hour: 8, days: [0, 6, 6, 9, 2.5], label: "Café", enabled: false, snoozedUntil: 1700000600000 }
  const save = both(p, "save", () => Legacy.saveAlarmSql(saved), "alarm.save", { id: saved.id, alarm: alarmCells(saved) }, service)
  assert.equal(save.res.err, undefined, JSON.stringify(save.res))
  const gone = both(p, "save a missing alarm", () => Legacy.saveAlarmSql({ ...saved, id: 999 }), "alarm.save", { id: 999, alarm: alarmCells(saved) }, service)
  assert.equal(Legacy.parseFound(gone.out), false)
  assert.equal(gone.res.err, "not_found")
  both(p, "insert a second", () => Legacy.insertAlarmSql({ ...ALARM, minute: 45 }), "alarm.insert", { alarm: alarmCells({ ...ALARM, minute: 45 }) }, service)
  const del = both(p, "delete", () => Legacy.deleteAlarmSql(saved.id), "alarm.delete", { id: saved.id }, service)
  assert.equal(del.res.err, undefined)
  const delMissing = both(p, "delete a missing alarm", () => Legacy.deleteAlarmSql(999), "alarm.delete", { id: 999 }, service)
  assert.equal(delMissing.res.err, "not_found")

  for (const [label, record, code] of [
    ["hour 24", { ...alarmCells(ALARM), hour: 24 }, "refused"],
    ["a label of 41 characters", { ...alarmCells(ALARM), label: "x".repeat(41) }, "refused"],
    ["snooze 0", { ...alarmCells(ALARM), snooze_minutes: 0 }, "refused"],
    ["a column left out", Object.fromEntries(Object.entries(alarmCells(ALARM)).filter(([k]) => k !== "armed_at_ms")), "bad_request"],
    ["an unknown column", { ...alarmCells(ALARM), ring: 1 }, "bad_request"],
    ["the id inside the record", { ...alarmCells(ALARM), id: 1 }, "bad_request"]
  ]) {
    const res = call(p.bin, { writes: [write("alarm.insert", { alarm: record }, service)] }).results[0]
    assert.equal(res.err, code, `${label}: ${JSON.stringify(res)}`)
    sameTables(p.old, p.bin, label)
  }

  // ADR-0015 and ADR-0016 are a lookup in the binary: a widget cannot write alarms, the service cannot write the rest.
  const widget = call(p.bin, { writes: [write("alarm.insert", { alarm: alarmCells(ALARM) }), write("alarm.save", { id: 1, alarm: alarmCells(ALARM) }, { id: 2 }), write("alarm.delete", { id: 1 }, { id: 3 })] })
  assert.deepEqual(widget.results.map((r) => r.err), ["forbidden", "forbidden", "forbidden"])
  const fromService = call(p.bin, { writes: [
    write("settings.set", { values: { volume: 1 } }, { by: "service" }),
    write("item.add", { type: "note", title: "x" }, { by: "service", id: 2 }),
    write("history.clear", {}, { by: "service", id: 3 }),
    write("backup", { day: "2026-09-28" }, { by: "service", id: 4 })
  ] })
  assert.deepEqual(fromService.results.map((r) => r.err), ["forbidden", "forbidden", "forbidden", "forbidden"])
  sameTables(p.old, p.bin, "the forbidden writes changed nothing")
})

test("a search matches the ids the old listSql matched, in the same order", (t) => {
  const p = pair(t)
  cli(p.bin, "INSERT INTO items (type, title, body, status, created_at, updated_at, position) VALUES ('note', 'Café com Leite', 'AÇÃO urgente', 0, 1, 1, 1), ('todo', 'ÑANDÚ 100%', 'a_b', 0, 1, 1, 2), ('note', 'Straße Ωmega', NULL, 1, 1, 1, 1), ('todo', 'back\\slash', 'x', 0, 1, 1, 3)")
  const views = []
  const expected = {}
  let n = 0
  for (const query of ["cafe", "CAFÉ", "acao", "100%", "a_b", "nandu", "straße", "ω", "\\", "_", "%", "zzz", "e"]) {
    for (const filter of ["all", "note", "todo", "bogus"]) {
      const key = "v" + n++
      // The caller trims before it sends, as listSql trimmed.
      views.push({ key, filter, query: query.trim() })
      expected[key] = rows(p.bin, Legacy.listSql(filter, query)).map((r) => r.id)
    }
  }
  const snap = call(p.bin, { sync: { since: -1, views } }).snapshot
  for (const view of views) assert.deepEqual(snap.matches[view.key], expected[view.key], `${JSON.stringify(view.query)} in ${view.filter}`)
  assert.ok(Object.values(expected).some((ids) => ids.length > 1), "some search matched more than one item")
  assert.ok(Object.values(expected).some((ids) => ids.length === 0), "some search matched nothing")
  // An empty query is every item of the filter, in list order.
  const empty = call(p.bin, { sync: { since: -1, views: [{ key: "all", filter: "all", query: "" }, { key: "todo", filter: "todo", query: "" }] } }).snapshot
  assert.deepEqual(empty.matches.all, rows(p.bin, Legacy.listSql("all", "")).map((r) => r.id))
  assert.deepEqual(empty.matches.todo, rows(p.bin, Legacy.listSql("todo", "")).map((r) => r.id))
})

test("the text the binary folds is the text searchText folds and the text the triggers fold", (t) => {
  const p = pair(t)
  // Every unit of the fold table, a surrogate pair, and some text the table leaves alone.
  let every = ""
  for (let u = 0; u < 0x10000; u++) {
    const c = String.fromCharCode(u)
    if (u < 0xd800 || u > 0xdfff) if (Legacy.searchText(c) !== c) every += c
  }
  const title = every.slice(0, 1200) + " 😀 abc"
  const body = every.slice(1200) + " Ωmega"
  const added = call(p.bin, { writes: [write("item.add", { type: "note", title, body })] }).results[0]
  // The same text through the CLI, which leaves the copy NULL, so items_search_insert folds it.
  cli(p.bin, `INSERT INTO items (type, title, body, status, created_at, updated_at) VALUES ('note', '${title.replace(/'/g, "''")}', '${body.replace(/'/g, "''")}', 0, 1, 1)`)
  const [bin, trigger] = rows(p.bin, `SELECT search_title, search_body FROM items WHERE id >= ${added.value} ORDER BY id`)
  assert.equal(bin.search_title, Legacy.searchText(title))
  assert.equal(bin.search_body, Legacy.searchText(body))
  assert.deepEqual(trigger, bin)
})
