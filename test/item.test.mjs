import { test } from "node:test"
import assert from "node:assert/strict"
import { loadQmlLib } from "./lib/load-qml-lib.mjs"

const Item = loadQmlLib(new URL("../ui/Item.js", import.meta.url), [
  "isTodo", "isReadOrCompleted", "statusLabel", "toggleVerb", "statusToast", "relativeAge", "indexOfId",
  "historyLabel", "neighbourId", "isRemoved", "dropMove"
])

const noteUnread = { type: "note", status: 0, title: "Ideas" }
const noteRead = { type: "note", status: 1, title: "Ideas" }
const todoPending = { type: "todo", status: 0, title: "Buy milk" }
const todoCompleted = { type: "todo", status: 1, title: "Buy milk" }

test("isTodo / isReadOrCompleted", () => {
  assert.equal(Item.isTodo(noteUnread), false)
  assert.equal(Item.isTodo(todoPending), true)
  assert.equal(Item.isReadOrCompleted(noteUnread), false)
  assert.equal(Item.isReadOrCompleted(noteRead), true)
  assert.equal(Item.isReadOrCompleted(todoPending), false)
  assert.equal(Item.isReadOrCompleted(todoCompleted), true)
})

test("statusLabel", () => {
  assert.equal(Item.statusLabel(noteUnread), "unread")
  assert.equal(Item.statusLabel(noteRead), "read")
  assert.equal(Item.statusLabel(todoPending), "pending")
  assert.equal(Item.statusLabel(todoCompleted), "completed")
})

test("toggleVerb", () => {
  assert.equal(Item.toggleVerb(noteUnread), "Mark read")
  assert.equal(Item.toggleVerb(noteRead), "Mark unread")
  assert.equal(Item.toggleVerb(todoPending), "Complete")
  assert.equal(Item.toggleVerb(todoCompleted), "Mark pending")
})

test("statusToast", () => {
  assert.equal(Item.statusToast(noteUnread, 1), "Marked read — Ideas")
  assert.equal(Item.statusToast(noteRead, 0), "Marked unread — Ideas")
  assert.equal(Item.statusToast(todoPending, 1), "Completed — Buy milk")
  assert.equal(Item.statusToast(todoCompleted, 0), "Marked pending — Buy milk")
})

test("relativeAge: under a minute", () => {
  assert.equal(Item.relativeAge(1000, 1000), "now")
  assert.equal(Item.relativeAge(1000, 1030), "now")
})

test("relativeAge: minutes", () => {
  assert.equal(Item.relativeAge(1000, 1000 + 12 * 60), "12m")
})

test("relativeAge: hours", () => {
  assert.equal(Item.relativeAge(1000, 1000 + 3 * 3600), "3h")
})

test("relativeAge: days", () => {
  assert.equal(Item.relativeAge(1000, 1000 + 2 * 86400), "2d")
})

test("relativeAge: exactly 30 days stays relative", () => {
  assert.equal(Item.relativeAge(0, 30 * 86400), "30d")
})

test("relativeAge: past 30 days falls back to the local date", (t) => {
  const realTz = process.env.TZ
  t.after(() => {
    if (realTz === undefined) delete process.env.TZ
    else process.env.TZ = realTz
  })
  const ts = Date.UTC(2023, 10, 14, 22, 13) / 1000
  const now = ts + 31 * 86400
  process.env.TZ = "UTC"
  assert.equal(Item.relativeAge(ts, now), "2023-11-14")
  process.env.TZ = "America/Sao_Paulo"
  assert.equal(Item.relativeAge(ts, now), "2023-11-14")
  process.env.TZ = "Asia/Tokyo"
  assert.equal(Item.relativeAge(ts, now), "2023-11-15")
})

test("indexOfId finds a row by id, comparing numbers and numeric strings alike", () => {
  const rows = [{ id: 7 }, { id: "12" }, { id: 3 }]
  assert.equal(Item.indexOfId(rows, 12), 1)
  assert.equal(Item.indexOfId(rows, "3"), 2)
  assert.equal(Item.indexOfId(rows, 99), -1)
  assert.equal(Item.indexOfId(null, 1), -1)
})

test("historyLabel: a note's status changes read as read and unread", () => {
  assert.equal(Item.historyLabel({ type: "note", action: "completed" }), "read")
  assert.equal(Item.historyLabel({ type: "note", action: "reopened" }), "unread")
  assert.equal(Item.historyLabel({ type: "note", action: "edited" }), "edited")
})

test("historyLabel: a todo keeps the stored action", () => {
  assert.equal(Item.historyLabel({ type: "todo", action: "completed" }), "completed")
  assert.equal(Item.historyLabel({ type: "todo", action: "reopened" }), "reopened")
  assert.equal(Item.historyLabel({ type: "todo", action: "deleted" }), "deleted")
})

test("neighbourId: the next row, or the previous one at the end", () => {
  const rows = [{ id: 7 }, { id: 12 }, { id: 3 }]
  assert.equal(Item.neighbourId(rows, 12), 3)
  assert.equal(Item.neighbourId(rows, 7), 12)
  assert.equal(Item.neighbourId(rows, 3), 12)
  assert.equal(Item.neighbourId([{ id: 7 }], 7), -1)
  assert.equal(Item.neighbourId(rows, 99), -1)
})

test("isRemoved: an unfiltered list proves a missing row is gone", () => {
  const rows = [{ id: 7 }, { id: 12 }]
  assert.equal(Item.isRemoved(12, rows, false, null), false)
  assert.equal(Item.isRemoved(3, rows, false, null), true)
})

test("isRemoved: a filtered list defers to every row, once loaded", () => {
  const listed = [{ id: 7 }]
  assert.equal(Item.isRemoved(12, listed, true, [{ id: 7 }, { id: 12 }]), false)
  assert.equal(Item.isRemoved(12, listed, true, [{ id: 7 }]), true)
  assert.equal(Item.isRemoved(12, listed, true, null), false)
  assert.equal(Item.isRemoved(7, listed, true, []), false)
})

// The visible rows: pending 1, 2, 3, then completed 4, 5.
const shown = [
  { id: 1, status: 0 }, { id: 2, status: 0 }, { id: 3, status: 0 }, { id: 4, status: 1 }, { id: 5, status: 1 }
]

test("dropMove: a drop at a slot of the block lands before the visible row there", () => {
  assert.deepEqual(Item.dropMove(shown, 3, 0), { anchorId: 1, after: false })
  assert.deepEqual(Item.dropMove(shown, 1, 2), { anchorId: 3, after: false })
  assert.deepEqual(Item.dropMove(shown, 5, 0), { anchorId: 4, after: false })
})

test("dropMove: a drop below the block's last row lands after it", () => {
  assert.deepEqual(Item.dropMove(shown, 1, 3), { anchorId: 3, after: true })
  assert.deepEqual(Item.dropMove(shown, 4, 2), { anchorId: 5, after: true })
})

test("dropMove: a drop right above or right below the item itself moves nothing", () => {
  assert.equal(Item.dropMove(shown, 2, 1), null)
  assert.equal(Item.dropMove(shown, 2, 2), null)
  assert.equal(Item.dropMove(shown, 3, 3), null)
  assert.equal(Item.dropMove(shown, 4, 0), null)
})

test("dropMove: a slot outside the block is clamped to it, and a missing item moves nothing", () => {
  assert.deepEqual(Item.dropMove(shown, 1, 9), { anchorId: 3, after: true })
  assert.deepEqual(Item.dropMove(shown, 5, -4), { anchorId: 4, after: false })
  assert.equal(Item.dropMove(shown, 9, 0), null)
  assert.equal(Item.dropMove([{ id: 1, status: 0 }], 1, 0), null)
})
