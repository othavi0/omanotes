#!/usr/bin/env bash
# Loads the real BarWidget, and the Panel it owns, against a seeded sqlite db,
# offscreen, without the alarm service, as an older shell would. Drives it
# through `qs ipc call` the way a script or keybind does, then asserts the
# JSON replies and the rows that reached the db.

set -euo pipefail
source "$(dirname "$0")/lib/harness.sh"
stub_keyboard_panel

# The binary is a stub (lib/stub-db.sh). While hold-reads exists, a read runs at once but
# answers only when the file is removed, so the test can write and reload in between. A
# held read that carried a search fails while the fail-list file exists.
stub_db

# The widget loads from its own path, outside the config dir, as the shell
# loads a plugin. Symlinked into the config dir, Panel.qml fails to resolve the
# types in ui/ ("Segment is not a type").
cat > "$cfg_dir/shell.qml" <<'QML'
import QtQuick
import Quickshell
import Quickshell.Io
import QtTest
import "ui/Icons.js" as Icons
import "ui/Tabs.js" as Tabs

ShellRoot {
  id: sr

  function panelState() {
    var w = widget.item
    return (w.panelItem ? "loaded" : "none") + "|" + (w.opened ? "open" : "closed")
  }
  // The Items tab and the History tab as they stand, with no turn run.
  function panelView() {
    var panel = widget.item.panelItem
    var itemsTab = sr.find(panel, "ItemsTab")
    return ["items", "alarms", "history", "settings"][panel.activeTab] + "|" + itemsTab.itemList.length + "|" + itemsTab.selectedId + "|" + itemsTab.editorTitle + "|draft:" + itemsTab.draftNew
      + "|history:" + sr.find(panel, "HistoryTab").selectedId
  }
  // What the panel shows in the turn it is created, before any event runs.
  property string viewAtLoad: ""
  Connections {
    target: widget.item
    function onPanelItemChanged() { if (widget.item.panelItem) sr.viewAtLoad = sr.panelView() }
  }
  function button() { return sr.find(widget.item, "WidgetButton") }

  function find(obj, typeName) {
    if (!obj) return null
    if (String(obj).indexOf(typeName) === 0) return obj
    var kids = obj.data || []
    for (var i = 0; i < kids.length; ++i) {
      var hit = sr.find(kids[i], typeName)
      if (hit) return hit
    }
    return null
  }
  function findAll(obj, match, out) {
    out = out || []
    if (!obj) return out
    if (match(obj)) out.push(obj)
    var kids = obj.data || []
    for (var i = 0; i < kids.length; ++i) sr.findAll(kids[i], match, out)
    return out
  }
  function findText(obj, part) {
    if (!obj) return null
    if (typeof obj.text === "string" && obj.text.indexOf(part) >= 0) return obj
    var kids = obj.data || []
    for (var i = 0; i < kids.length; ++i) {
      var hit = sr.findText(kids[i], part)
      if (hit) return hit
    }
    return null
  }

  // The button away from the corner where offscreen puts the pointer at the
  // start, whose hover would load the panel.
  FloatingWindow {
    implicitWidth: 200; implicitHeight: 40
    Loader {
      id: widget
      x: 100
      width: item ? item.implicitWidth : 0
      height: 40
      source: "file://" + Quickshell.env("OMANOTES_WORKTREE") + "/BarWidget.qml"
    }
  }
  TestEvent { id: pointer }

  // Typing into the editor has no IPC, so the test reaches the panel's ItemsTab.
  IpcHandler {
    target: "omanotes-test"
    function panelState(): string { return sr.panelState() }
    function hover(): string {
      var b = sr.button()
      pointer.mouseMove(b, b.width / 2, b.height / 2, -1, Qt.NoButton, Qt.NoModifier)
      return sr.panelState()
    }
    function click(): string {
      var b = sr.button()
      pointer.mouseClick(b, b.width / 2, b.height / 2, Qt.LeftButton, Qt.NoModifier, -1)
      return sr.panelState()
    }
    // The click comes in the same turn as the hover, before the load it
    // started can finish.
    function hoverAndClick(): string {
      var b = sr.button()
      pointer.mouseMove(b, b.width / 2, b.height / 2, -1, Qt.NoButton, Qt.NoModifier)
      var before = sr.panelState()
      pointer.mouseClick(b, b.width / 2, b.height / 2, Qt.LeftButton, Qt.NoModifier, -1)
      return before + ">" + sr.panelState()
    }
    // A new BarWidget in place of the old one, with its own Db and no panel.
    // Two calls, so the old widget's scratchpad handler is gone before the
    // new one registers.
    function dropWidget(): void { widget.active = false }
    function newWidget(): void { widget.active = true }
    function panelView(): string { return sr.panelView() }
    function viewAtLoad(): string { return sr.viewAtLoad }
    function typeDraft(title: string): string {
      var itemsTab = sr.find(widget.item.panelItem, "ItemsTab")
      if (!itemsTab) return "no ItemsTab"
      itemsTab.startNew("note")
      itemsTab.editorTitle = title
      return "ok"
    }
    function filterPanel(type: string, query: string): string {
      var itemsTab = sr.find(widget.item.panelItem, "ItemsTab")
      if (!itemsTab) return "no ItemsTab"
      itemsTab.filterType = type
      itemsTab.searchText = query
      return "ok"
    }
    // A drop, as the list makes it, and the order the list shows.
    function moveItem(id: int, anchorId: int, after: bool): string { return widget.item.panelItem.db.move(id, anchorId, after) }
    function order(): string { return widget.item.panelItem.db.items.map(function(i) { return i.id }).join(",") }
    function reloadPanel(): void { widget.item.panelItem.db.load() }
    // How long the lanes let a spawn run before they kill it.
    function setLimits(spawnMs: int, writeMs: int): void {
      var store = widget.item.panelItem.db._store.target
      store.spawnLimitMs = spawnMs
      store.writeLimitMs = writeMs
    }
    function commitEditor(): string {
      var itemsTab = sr.find(widget.item.panelItem, "ItemsTab")
      if (!itemsTab) return "no ItemsTab"
      itemsTab.commitEditor(false)
      return "ok"
    }
    // A search too long for the argv of an IPC call.
    function searchRepeated(text: string, times: int): string {
      var itemsTab = sr.find(widget.item.panelItem, "ItemsTab")
      if (!itemsTab) return "no ItemsTab"
      itemsTab.searchText = text.repeat(times)
      return "ok"
    }
    function panelRows(): int {
      var itemsTab = sr.find(widget.item.panelItem, "ItemsTab")
      return itemsTab ? itemsTab.itemList.length : -1
    }
    function editItem(id: int, title: string): string {
      var itemsTab = sr.find(widget.item.panelItem, "ItemsTab")
      if (!itemsTab) return "no ItemsTab"
      itemsTab.pickItem(id)
      itemsTab.editorTitle = title
      itemsTab.toast.text = ""
      return "ok"
    }
    function editorState(): string {
      var itemsTab = sr.find(widget.item.panelItem, "ItemsTab")
      if (!itemsTab) return "no ItemsTab"
      return itemsTab.selectedId + "|" + itemsTab.editorTitle + "|toast:" + itemsTab.toast.text
    }
    // Writes as the panel's user makes them, so a failure reaches the toast.
    function userWrite(method: string, id: string): string {
      var itemsTab = sr.find(widget.item.panelItem, "ItemsTab")
      if (!itemsTab) return "no ItemsTab"
      itemsTab.toast.text = ""
      var db = widget.item.panelItem.db
      if (method === "setStatus") db.setStatus(id, 1)
      else if (method === "update") db.update(id, "USER-WRITE", "")
      else db[method](id)
      return "ok"
    }
    function dbState(): string {
      var db = widget.item.panelItem.db
      return db.totalNotes + "|" + db.totalHistory + "|" + (db.history.length ? db.history[0].title : "")
    }
    function countLabels(): string {
      var button = sr.find(widget.item, "WidgetButton")
      var header = sr.findText(sr.find(widget.item.panelItem, "PanelHeader"), " unread · ")
      return (button ? button.tooltipText : "no WidgetButton") + "|" + (header ? header.text : "no count")
    }
    function noService(): string {
      var button = sr.find(widget.item, "WidgetButton")
      var alarmsTab = sr.find(widget.item.panelItem, "AlarmsTab")
      var empty = alarmsTab ? sr.findText(alarmsTab, "Omanotes service") : null
      return String(widget.item.service) + "|" + (button.text === Icons.noteFilled ? "note glyph" : button.text) + "|" + button.implicitWidth
        + "|" + (empty ? empty.text : "no empty state")
    }
    // The Settings tab of a panel without the service: the gear is there,
    // the sound pages are there, and only the buttons that play say why
    // they do nothing.
    function noServiceSettings(): string {
      var panel = widget.item.panelItem
      var header = sr.find(panel, "PanelHeader")
      var segment = sr.find(header, "Segment")
      var gear = segment.options[3]
      panel.activeTab = Tabs.settings
      var tab = sr.find(panel, "SettingsTab")
      var inert = sr.findAll(tab, function(o) { return o.visible && o.tooltipText === "Needs the Omanotes service" })
      return gear.tooltip + "|" + (gear.icon === Icons.cog ? "cog" : gear.icon) + "|" + (tab ? tab.section : "no SettingsTab")
        + "|" + inert.length + " inert"
    }
    function toast(): string {
      var itemsTab = sr.find(widget.item.panelItem, "ItemsTab")
      return itemsTab ? itemsTab.toast.text : "no ItemsTab"
    }
    function quit(): void { Qt.exit(0) }
  }
}
QML

PATH="$cfg_dir/bin:$PATH" OMANOTES_WORKTREE="$stub_tree" "${qs_cmd[@]}" > "$cfg_dir/qs.log" 2>&1 &
qs_pid=$!
trap 'kill "$qs_pid" 2> /dev/null || true; wait "$qs_pid" 2> /dev/null || true; rm -rf "$cfg_dir" "$data_home"' EXIT

ipc() { qs -p "$cfg_dir" ipc call "$@" 2>&1; }

up=0
for _ in $(seq 50); do
  [[ "$(ipc scratchpad ping)" == '{"ok":true}' ]] && { up=1; break; }
  sleep 0.2
done
if (( ! up )); then cat "$cfg_dir/qs.log"; echo "the bar widget never answered ping"; exit 2; fi

checks=0
failures=0
pass() { checks=$((checks + 1)); echo "ok   $1"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); echo "FAIL $1"; }
# Writes land asynchronously, so poll the db until it matches or 10 s pass.
expect() {
  local what="$1" sql="$2" want="$3" got=""
  for _ in $(seq 50); do
    got="$(sqlite3 "$db" "$sql" 2>&1)" && [[ "$got" == "$want" ]] && { pass "$what"; return; }
    sleep 0.2
  done
  fail "$what: want '$want', got '$got'"
}
replies() {
  local what="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then pass "$what"; else fail "$what: want '$want', got '$got'"; fi
}
by_id() { node -e 'console.log(JSON.stringify(JSON.parse(process.argv[1]).sort((a, b) => a.id - b.id)))' "$1"; }
all_of() {
  by_id "$(sqlite3 "$db" "SELECT json_group_array(json_object('id', id, 'type', type, 'title', title, 'body', COALESCE(body, ''), 'status', status)) FROM items WHERE type = '$1'")"
}

replies "ping answers JSON" "$(ipc scratchpad ping)" '{"ok":true}'

# The panel is created on demand and then kept (ADR-0019).
panel_is() {
  local what="$1" want="$2" got=""
  for _ in $(seq 50); do
    got="$(ipc omanotes-test panelState)"
    [[ "$got" == "$want" ]] && break
    sleep 0.1
  done
  replies "$what" "$got" "$want"
}
# The panel as it shows right after it is created: the Items tab, every row,
# the first one selected and in the editor, and the newest history entry
# selected.
view_now() {
  local first newest
  first="$(sqlite3 "$db" "SELECT id || '|' || title FROM items ORDER BY status, position, id DESC LIMIT 1")"
  newest="$(sqlite3 "$db" "SELECT id FROM history ORDER BY ts DESC, id DESC LIMIT 1")"
  echo "items|$(sqlite3 "$db" "SELECT COUNT(*) FROM items")|$first|draft:false|history:$newest"
}
# A new widget, after its Db has loaded and its first reads are done.
new_widget() {
  ipc omanotes-test dropWidget > /dev/null
  ipc omanotes-test newWidget > /dev/null
  for _ in $(seq 50); do
    [[ "$(ipc scratchpad listNotes)" == '[{'* ]] && break
    sleep 0.1
  done
  sleep 0.5
}
sleep 1
replies "no panel exists after the start, and the list IPC and a close load none" \
  "$(ipc scratchpad listNotes > /dev/null; ipc scratchpad close; ipc omanotes-test panelState)" "none|closed"
replies "an IPC open with no hover loads the panel and opens it at once" "$(ipc scratchpad open; ipc omanotes-test panelState)" "loaded|open"
replies "in the turn it is created, the panel shows the rows its Db already held, the first selected" \
  "$(ipc omanotes-test viewAtLoad)" "$(view_now)"
ipc scratchpad close > /dev/null
replies "closed, the panel stays loaded" "$(sleep 0.5; ipc omanotes-test panelState)" "loaded|closed"

new_widget
replies "a new widget has no panel" "$(ipc omanotes-test panelState)" "none|closed"
reads="$(wc -l < "$cfg_dir/db.log")"
replies "the pointer entering the button loads the panel without opening it" "$(ipc omanotes-test hover)" "none|closed"
panel_is "the load in the background ends" "loaded|closed"
replies "loaded in the background, the panel shows the rows its Db already held, the first selected" \
  "$(ipc omanotes-test viewAtLoad)" "$(view_now)"
replies "and the hover read nothing from the database" "$(sleep 0.5; wc -l < "$cfg_dir/db.log")" "$reads"
replies "a click then opens it" "$(ipc omanotes-test click)" "loaded|open"
replies "on the Items tab with every row, the first selected" "$(ipc omanotes-test panelView)" "$(view_now)"
ipc omanotes-test click > /dev/null

new_widget
replies "a click before the load the hover started has ended opens the panel once it is ready" \
  "$(ipc omanotes-test hoverAndClick)" "none|closed>loaded|open"
replies "with its rows" "$(ipc omanotes-test panelView)" "$(view_now)"
replies "the IPC reaches the new widget" "$(ipc scratchpad close; ipc omanotes-test panelState)" "loaded|closed"

want_counts="Omanotes: 1 unread · 2 pending|1 unread · 2 pending"
counts=""
for _ in $(seq 50); do
  counts="$(ipc omanotes-test countLabels)"
  [[ "$counts" == "$want_counts" ]] && break
  sleep 0.2
done
replies "the bar tooltip and the panel header count unread notes and pending todos" "$counts" "$want_counts"
replies "without a service the chip is the note glyph in the icon slot and the Alarms tab says so" \
  "$(ipc omanotes-test noService)" "null|note glyph|27|Alarms need the Omanotes service"
replies "without a service the gear opens Settings on the sound, whose six play buttons and Test say they need it" \
  "$(ipc omanotes-test noServiceSettings)" "Settings|cog|sound|7 inert"

# Reopens leave positions under the column default of 0, and a new item that
# took the default would land below them.
replies "a first-block item takes position -5" \
  "$(sqlite3 "$db" "UPDATE items SET position = -5 WHERE id = 2; SELECT changes();" 2>&1 || true)" "1"

replies "addNote answers ok" "$(ipc scratchpad addNote "IPC-NOTE" "ipc body")" '{"ok":true}'
expect "addNote writes the note" \
  "SELECT type || '|' || body || '|' || status FROM items WHERE title = 'IPC-NOTE'" "note|ipc body|0"
replies "addNote with an empty title is refused" "$(ipc scratchpad addNote "  " "")" '{"ok":false,"error":"title is required"}'
replies "addTodo answers ok" "$(ipc scratchpad addTodo "IPC-TODO" "todo body")" '{"ok":true}'
expect "addTodo writes the todo" \
  "SELECT type || '|' || body || '|' || status FROM items WHERE title = 'IPC-TODO'" "todo|todo body|0"
replies "addTodo with an empty title is refused" "$(ipc scratchpad addTodo "" "")" '{"ok":false,"error":"title is required"}'
expect "items added through the IPC land at the top of the first block" \
  "SELECT group_concat(title, '|') FROM (SELECT title FROM items WHERE status = 0 ORDER BY position, id DESC LIMIT 2)" \
  "IPC-TODO|IPC-NOTE"
# listTodos reads the same order the panel shows.
stored_todos="$(sqlite3 "$db" "SELECT group_concat(id) FROM (SELECT id FROM items WHERE type = 'todo' ORDER BY status, position, id DESC)" 2>&1 || true)"
listed_todos=""
for _ in $(seq 50); do
  listed_todos="$(node -e 'console.log(JSON.parse(process.argv[1]).map(t => t.id).join(","))' "$(ipc scratchpad listTodos)" 2> /dev/null)"
  [[ "$listed_todos" == "$stored_todos" ]] && break
  sleep 0.2
done
replies "listTodos lists the todos in the stored order" "$listed_todos" "$stored_todos"

note_id="$(sqlite3 "$db" "SELECT id FROM items WHERE title = 'IPC-NOTE'")"
# listNotes answers from the widget's cache, which catches up on the reload after the write.
listed=""
for _ in $(seq 50); do
  listed="$(ipc scratchpad listNotes)"
  [[ "$listed" == *'"IPC-NOTE"'* ]] && break
  sleep 0.2
done
replies "listNotes returns every note with its fields" "$(by_id "$listed")" "$(all_of note)"

replies "toggleTodo answers ok" "$(ipc scratchpad toggleTodo 2)" '{"ok":true}'
expect "toggleTodo completes the pending todo" "SELECT status FROM items WHERE id = 2" "1"
expect "toggleTodo is logged in history" \
  "SELECT COUNT(*) FROM history WHERE action = 'completed' AND title = 'Renew the domain'" "1"
for _ in $(seq 50); do
  node -e 'process.exit(JSON.parse(process.argv[1]).some(t => t.id === 2 && t.status === 1) ? 0 : 1)' \
    "$(ipc scratchpad listTodos)" && break
  sleep 0.2
done
replies "toggleStatus answers ok for a todo" "$(ipc scratchpad toggleStatus 2)" '{"ok":true}'
expect "toggleStatus reopens the completed todo" "SELECT status FROM items WHERE id = 2" "0"
expect "the reopen is logged in history" \
  "SELECT COUNT(*) FROM history WHERE action = 'reopened' AND title = 'Renew the domain'" "1"
replies "toggleTodo on a missing id is refused" "$(ipc scratchpad toggleTodo 999)" '{"ok":false,"error":"item not found: 999"}'

replies "toggleStatus answers ok for a note" "$(ipc scratchpad toggleStatus 1)" '{"ok":true}'
expect "toggleStatus marks the unread note read" "SELECT status FROM items WHERE id = 1" "1"
expect "toggleStatus is logged in history" \
  "SELECT COUNT(*) FROM history WHERE action = 'completed' AND title = 'Ideas for the panel'" "1"
for _ in $(seq 50); do
  node -e 'process.exit(JSON.parse(process.argv[1]).some(n => n.id === 1 && n.status === 1) ? 0 : 1)' \
    "$(ipc scratchpad listNotes)" && break
  sleep 0.2
done
replies "toggleTodo, kept as an alias, answers ok for a note" "$(ipc scratchpad toggleTodo 1)" '{"ok":true}'
expect "toggleTodo marks the read note unread" "SELECT status FROM items WHERE id = 1" "0"
replies "toggleStatus on a missing id is refused" "$(ipc scratchpad toggleStatus 999)" '{"ok":false,"error":"item not found: 999"}'

# The panel shares the widget's Db, so its filter and search must not narrow the IPC.
replies "the panel takes a filter and a search" "$(ipc omanotes-test filterPanel note coffee)" "ok"
rows=""
for _ in $(seq 50); do
  rows="$(ipc omanotes-test panelRows)"
  [[ "$rows" == "1" ]] && break
  sleep 0.2
done
replies "the filtered panel lists one row" "$rows" "1"
# The cache may still be catching up on the reopen above, so poll.
lists_all() {
  local what="$1" call="$2" type="$3" got="" want
  want="$(all_of "$type")"
  for _ in $(seq 50); do
    got="$(by_id "$(ipc scratchpad "$call")")"
    [[ "$got" == "$want" ]] && break
    sleep 0.2
  done
  replies "$what" "$got" "$want"
}
lists_all "listNotes ignores the panel's filter" listNotes note
lists_all "listTodos ignores the panel's filter" listTodos todo
replies "toggleTodo finds a todo the panel hides" "$(ipc scratchpad toggleTodo 3)" '{"ok":true}'
expect "toggleTodo completes the hidden todo" "SELECT status FROM items WHERE id = 3" "1"
ipc omanotes-test filterPanel all "" > /dev/null

replies "remove answers ok" "$(ipc scratchpad remove "$note_id")" '{"ok":true}'
expect "remove deletes the item" "SELECT COUNT(*) FROM items WHERE id = $note_id" "0"
expect "remove is logged in history" \
  "SELECT COUNT(*) FROM history WHERE action = 'deleted' AND title = 'IPC-NOTE'" "1"
replies "remove on a missing id is refused" "$(ipc scratchpad remove 999)" '{"ok":false,"error":"item not found: 999"}'

replies "clearHistory answers ok" "$(ipc scratchpad clearHistory)" '{"ok":true}'
expect "clearHistory empties history" "SELECT COUNT(*) FROM history" "0"
expect "clearHistory keeps the items" "SELECT COUNT(*) FROM items" "7"

# A script writing while the user edits in the open panel must not move the
# selection, commit the half-typed title or raise the panel's toasts.
ipc scratchpad open > /dev/null
rows=""
for _ in $(seq 50); do
  rows="$(ipc omanotes-test panelRows)"
  [[ "$rows" == "7" ]] && break
  sleep 0.2
done
replies "the open panel edits item 2" "$(ipc omanotes-test editItem 2 "Renew the domain HALF-TYPED")" "ok"
ipc scratchpad toggleTodo 2 > /dev/null
ipc scratchpad clearHistory > /dev/null
ipc scratchpad addNote "FROM-SCRIPT" "" > /dev/null
# Writes run in order, so the reload that shows the last one follows them all.
for _ in $(seq 50); do
  rows="$(ipc omanotes-test panelRows)"
  [[ "$rows" == "8" ]] && break
  sleep 0.2
done
replies "the panel lists the script's note" "$rows" "8"
replies "script writes leave the selection, the editor and the toast alone" \
  "$(ipc omanotes-test editorState)" "2|Renew the domain HALF-TYPED|toast:"
# A write queued behind any commit the panel made lands after it.
ipc scratchpad toggleTodo 3 > /dev/null
expect "a later script write lands" "SELECT status FROM items WHERE id = 3" "0"
replies "script writes do not commit the open edit" \
  "$(sqlite3 "$db" "SELECT title FROM items WHERE id = 2")" "Renew the domain"
ipc scratchpad close > /dev/null
expect "closing the panel commits the edit" "SELECT title FROM items WHERE id = 2" "Renew the domain HALF-TYPED"

ipc scratchpad open > /dev/null
replies "the open panel takes a draft" "$(ipc omanotes-test typeDraft "DRAFT-ON-CLOSE")" "ok"
ipc scratchpad close > /dev/null
expect "an unsaved draft is saved when the panel closes" \
  "SELECT COUNT(*) FROM items WHERE title = 'DRAFT-ON-CLOSE'" "1"

logged_failures() { grep -o "omanotes db: .*" "$cfg_dir/qs.log" | sed 's/^omanotes db: //' | tr '\n' ';' || true; }
replies "no db failure logged before the failure cases" "$(logged_failures)" ""

toast_is() {
  local what="$1" want="$2" got=""
  for _ in $(seq 50); do
    got="$(ipc omanotes-test toast)"
    [[ "$got" == "$want" ]] && break
    sleep 0.2
  done
  replies "$what" "$got" "$want"
}

for method in update setStatus convertType deleteItem; do
  ipc omanotes-test userWrite "$method" 999 > /dev/null
  toast_is "$method on a missing id shows the toast" "Error: item not found"
done

ipc omanotes-test userWrite deleteItem abc > /dev/null
toast_is "a non-numeric id is refused" "Error: invalid id: abc"

(printf 'BEGIN EXCLUSIVE;\n'; sleep 6; printf 'COMMIT;\n') | sqlite3 "$db" &
holder=$!
for _ in $(seq 50); do
  sqlite3 "$db" "SELECT COUNT(*) FROM items" > /dev/null 2>&1 || break
  sleep 0.05
done
ipc omanotes-test userWrite update 2 > /dev/null
toast_is "a write against a locked database shows sqlite3's message" "Error: database is locked"
wait "$holder"
replies "the refused write left the item alone" \
  "$(sqlite3 "$db" "SELECT title FROM items WHERE id = 2")" "Renew the domain HALF-TYPED"

# From here the test writes with sqlite3 directly, as a user or another tool
# does, and never asks the Db to reload: the file watcher alone brings it in.
external_note() {
  sqlite3 "$db" "INSERT INTO items (type, title, status, created_at, updated_at)
      VALUES ('note', '$1', 0, strftime('%s', 'now'), strftime('%s', 'now'));
    INSERT INTO history (type, title, action, ts) VALUES ('note', '$1', 'added', strftime('%s', 'now'));"
}
caught_up() {
  local what="$1" got="" want
  want="$(sqlite3 "$db" "SELECT (SELECT COUNT(*) FROM items WHERE type = 'note') || '|'
    || (SELECT COUNT(*) FROM history) || '|' || (SELECT title FROM history ORDER BY ts DESC, id DESC LIMIT 1)")"
  for _ in $(seq 50); do
    got="$(ipc omanotes-test dbState)"
    [[ "$got" == "$want" ]] && break
    sleep 0.2
  done
  replies "$what" "$got" "$want"
}
hold_reads() { held_from="$(wc -l < "$cfg_dir/db.log")"; touch "$cfg_dir/hold-reads"; }
release_reads() { rm -f "$cfg_dir/hold-reads" "$cfg_dir/fail-list"; }
# One request reads what four did, so a reload holds one read.
all_reads_held() {
  for _ in $(seq 50); do
    (( $(wc -l < "$cfg_dir/db.log") > held_from )) && { pass "$1"; return; }
    sleep 0.2
  done
  fail "$1: no read was held"
}
panel_rows_are() {
  local what="$1" want="$2" got=""
  for _ in $(seq 50); do
    got="$(ipc omanotes-test panelRows)"
    [[ "$got" == "$want" ]] && break
    sleep 0.2
  done
  replies "$what" "$got" "$want"
}

external_note "EXTERNAL"
caught_up "counts and history pick up a write made outside the Db"
lists_all "listNotes shows a note written outside the Db" listNotes note

ipc omanotes-test filterPanel note overlap > /dev/null
panel_rows_are "the panel lists no note that matches overlap" 0
hold_reads
external_note "OVERLAP-1"
all_reads_held "the reload after the first write holds its read"
external_note "OVERLAP-2"
sleep 1
release_reads
caught_up "counts and history re-run for a write that lands while they read"
panel_rows_are "the filtered list re-runs for a write that lands while it reads" 2

ipc omanotes-test filterPanel todo e > /dev/null
panel_rows_are "the panel lists the todos that match e" \
  "$(sqlite3 "$db" "SELECT COUNT(*) FROM items WHERE type = 'todo' AND (search_title LIKE '%e%' OR search_body LIKE '%e%')")"
hold_reads
touch "$cfg_dir/fail-list"
external_note "OVERLAP-3"
all_reads_held "the reload after the third write holds its read"
ipc omanotes-test filterPanel note coffee > /dev/null
sleep 0.5
release_reads
panel_rows_are "a failed list read re-runs with the latest filter and search" 1

ipc omanotes-test filterPanel all "" > /dev/null
sleep 1
ipc omanotes-test filterPanel all "extern" > /dev/null
panel_rows_are "a search lists what it matches" \
  "$(sqlite3 "$db" "SELECT COUNT(*) FROM items WHERE search_title LIKE '%extern%' OR search_body LIKE '%extern%'")"
searched="$(grep '"query":"extern"' "$cfg_dir/db.log" || true)"
replies "a search asks for the ids after the stamp shown, not for every row again" \
  "$(grep -c '"since":-1' <<< "$searched" || true)|$(( $(grep -c '"since":' <<< "$searched" || true) >= 1 ))" "0|1"
ipc omanotes-test searchRepeated x 60000 > /dev/null
panel_rows_are "a search of 60 000 characters lists nothing" 0
replies "it goes out cut to 200 characters, under SQLite's limit on a LIKE pattern" \
  "$(grep -o '"query":"x*"' "$cfg_dir/db.log" | awk '{ print length($0) - 10 }' | sort -n | tail -1)" "200"
ipc omanotes-test searchRepeated "中" 20000 > /dev/null
panel_rows_are "a search of 20 000 characters of 3 bytes lists nothing, and no view's reload fails for it" 0
ipc omanotes-test filterPanel all "" > /dev/null

# A read sent before a drop lands while the drop's write waits on a lock: the
# list keeps the drop until a snapshot that includes the write lands.
sleep 1
IFS=, read -r top second < <(sqlite3 "$db" "SELECT group_concat(id) FROM (SELECT id FROM items WHERE status = 0 ORDER BY position, id DESC LIMIT 2)")
listed="$(ipc omanotes-test order)"
dropped="$second,$top,${listed#"$top,$second,"}"
hold_reads
ipc omanotes-test reloadPanel > /dev/null
all_reads_held "the reload before the drop holds its read"
touch "$cfg_dir/hold-any-write"
ipc omanotes-test moveItem "$second" "$top" false > /dev/null
replies "the drop shows at once" "$(ipc omanotes-test order)" "$dropped"
release_reads
sleep 1
replies "the read from before the drop lands and the list still shows the drop" "$(ipc omanotes-test order)" "$dropped"
rm -f "$cfg_dir/hold-any-write"
expect "the drop's write lands" \
  "SELECT group_concat(id) FROM (SELECT id FROM items WHERE status = 0 ORDER BY position, id DESC LIMIT 2)" "$second,$top"
replies "and the list shows the file's order, the same" "$(ipc omanotes-test order)" "$dropped"

# A request killed part way: its first write, a new note, committed, and the
# second hung on the disk until the lane killed the request. The note is in
# the file, so it must not come back to the editor, where saving it again
# adds it twice (issue #57).
if stall_journal_lib; then
  sleep 1
  open_id="$(sqlite3 "$db" "SELECT id FROM items WHERE status = 0 AND id <> 3 ORDER BY id LIMIT 1")"
  ipc omanotes-test setLimits 1500 0 > /dev/null
  touch "$cfg_dir/hold-any-write"
  ipc omanotes-test userWrite setStatus 3 > /dev/null
  ipc omanotes-test typeDraft "KILLED-MID-BATCH" > /dev/null
  ipc omanotes-test commitEditor > /dev/null
  ipc omanotes-test userWrite setStatus "$open_id" > /dev/null
  echo 2 > "$cfg_dir/stall-journal"
  rm -f "$cfg_dir/hold-any-write"
  expect "the note written before the kill is in the file" "SELECT COUNT(*) FROM items WHERE title = 'KILLED-MID-BATCH'" "1"
  replies "the add and the status change went out in one request" \
    "$(grep -c 'write:item.add write:item.status' "$cfg_dir/db.log")" "1"
  sleep 3
  rm -f "$cfg_dir/stall-journal"
  ipc omanotes-test setLimits 30000 5000 > /dev/null
  replies "the note does not come back to the editor as a draft" "$(ipc omanotes-test panelView | cut -d'|' -f4,5)" "KILLED-MID-BATCH|draft:false"
  ipc omanotes-test commitEditor > /dev/null
  sleep 1
  expect "saving the editor again does not add the note twice" "SELECT COUNT(*) FROM items WHERE title = 'KILLED-MID-BATCH'" "1"
  expect "the write the kill cut off left its item alone" "SELECT status FROM items WHERE id = $open_id" "0"
else
  echo "skip the request killed part way: no C compiler (cc)"
fi

ipc omanotes-test quit > /dev/null || true
wait "$qs_pid" || true
replies "only the failure cases are logged" "$(logged_failures)" \
  "item not found;item not found;item not found;item not found;invalid id: abc;database is locked;read failed: disk I/O error;the database helper stopped without an answer;read failed: the database helper stopped without an answer;"

# A Panel.qml that fails to load, as a broken update could leave it: the
# engine keeps the failed compile, so the widget must stay usable without it.
broken_tree="$cfg_dir/broken-tree"
cp -a "$stub_tree" "$broken_tree"
rm "$broken_tree/Panel.qml"
printf 'import QtQuick\nItem { propertyTheKitDropped: true }\n' > "$broken_tree/Panel.qml"
PATH="$cfg_dir/bin:$PATH" OMANOTES_WORKTREE="$broken_tree" "${qs_cmd[@]}" > "$cfg_dir/qs-broken.log" 2>&1 &
qs_pid=$!
up=0
for _ in $(seq 50); do
  [[ "$(ipc scratchpad ping)" == '{"ok":true}' ]] && { up=1; break; }
  sleep 0.2
done
replies "with a broken Panel.qml the widget still answers" "$up" "1"
replies "an IPC open with a broken Panel.qml opens nothing" "$(ipc scratchpad open; ipc omanotes-test panelState)" "none|closed"
replies "a hover and a second open after it load nothing again" \
  "$(ipc omanotes-test hover > /dev/null; sleep 0.3; ipc scratchpad toggle; ipc omanotes-test panelState)" "none|closed"
replies "the list IPC still answers" "$(ipc scratchpad listNotes | head -c 2)" "[{"
ipc omanotes-test quit > /dev/null || true
wait "$qs_pid" || true
replies "the failed load is one line in the log, and no call threw" \
  "$(grep -c "Panel.qml failed to load" "$cfg_dir/qs-broken.log")|$(grep -c "TypeError" "$cfg_dir/qs-broken.log" || true)" "1|0"

(( failures == 0 )) || tail -n 40 "$cfg_dir/qs.log"
echo "panel: $checks checks, $failures failed"
exit $(( failures > 0 ))
