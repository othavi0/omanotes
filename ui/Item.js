.pragma library

// Item semantics — the single place that reads `type`/`status` off a row.
// Views call these instead of repeating `Number(x.status) === 1` and the
// note/todo ternaries.

function isTodo(item) {
  return !!item && item.type === "todo"
}

function isReadOrCompleted(item) {
  return !!item && Number(item.status) === 1
}

// "pending" | "completed" (todos) or "unread" | "read" (notes).
function statusLabel(item) {
  if (!item) return ""
  if (isTodo(item)) return isReadOrCompleted(item) ? "completed" : "pending"
  return isReadOrCompleted(item) ? "read" : "unread"
}

// Label for the button that flips status.
function toggleVerb(item) {
  if (!item) return ""
  if (isTodo(item)) return isReadOrCompleted(item) ? "Mark pending" : "Complete"
  return isReadOrCompleted(item) ? "Mark unread" : "Mark read"
}

// Toast text after `item`'s status is set to `status` (0 or 1).
function statusToast(item, status) {
  if (!item) return ""
  var readOrCompleted = Number(status) === 1
  var verb = isTodo(item)
    ? (readOrCompleted ? "Completed" : "Marked pending")
    : (readOrCompleted ? "Marked read" : "Marked unread")
  return verb + " — " + item.title
}

// "now", "12m", "3h", "2d", or "YYYY-MM-DD" once the age passes 30 days.
function relativeAge(tsSeconds, nowSeconds) {
  var delta = Math.max(0, Number(nowSeconds) - Number(tsSeconds))
  if (delta < 60) return "now"
  var minutes = Math.floor(delta / 60)
  if (minutes < 60) return minutes + "m"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h"
  var days = Math.floor(hours / 24)
  if (days <= 30) return days + "d"
  var d = new Date(Number(tsSeconds) * 1000)
  function pad(n) { return (n < 10 ? "0" : "") + n }
  return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
}

function indexOfId(rows, id) {
  var list = rows || []
  for (var i = 0; i < list.length; ++i)
    if (Number(list[i].id) === Number(id)) return i
  return -1
}

// The row to select once `id` is deleted: the next one, or the previous one
// when `id` is last. -1 when no other row is left.
function neighbourId(rows, id) {
  var idx = indexOfId(rows, id)
  if (idx < 0) return -1
  if (idx + 1 < rows.length) return rows[idx + 1].id
  return idx > 0 ? rows[idx - 1].id : -1
}

// Whether the row `id` is gone from the database, judged by a reload.
// `listed` misses the rows a filter hides, so when it is filtered only
// `allRows`, the unfiltered rows or null until they load, can tell.
function isRemoved(id, listed, filtered, allRows) {
  if (indexOfId(listed, id) >= 0) return false
  if (!filtered) return true
  return !!allRows && indexOfId(allRows, id) < 0
}

// The action a history entry shows. A note's toggle is stored as completed or
// reopened, like a todo's, so it reads as read or unread here.
function historyLabel(entry) {
  if (!entry) return ""
  var action = String(entry.action || "")
  if (isTodo(entry)) return action
  if (action === "completed") return "read"
  if (action === "reopened") return "unread"
  return action
}
