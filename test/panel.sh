#!/usr/bin/env bash
# Loads the real BarWidget, and the Panel it owns, against a seeded sqlite db,
# offscreen. Drives it through `qs ipc call` the way a script or keybind does,
# then asserts the JSON replies and the rows that reached the db.

set -euo pipefail
source "$(dirname "$0")/lib/harness.sh"
stub_keyboard_panel

# The widget loads from its own path, outside the config dir, as the shell
# loads a plugin. Symlinked into the config dir, Panel.qml fails to resolve the
# types in ui/ ("Segment is not a type").
cat > "$cfg_dir/shell.qml" <<'QML'
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: sr

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

  FloatingWindow {
    implicitWidth: 40; implicitHeight: 40
    Loader { id: widget; anchors.fill: parent; source: "file://" + Quickshell.env("OMANOTES_WORKTREE") + "/BarWidget.qml" }
  }

  // Typing into the editor has no IPC, so the test reaches the panel's MainTab.
  IpcHandler {
    target: "omanotes-test"
    function typeDraft(title: string): string {
      var mainTab = sr.find(widget.item.panelItem, "MainTab")
      if (!mainTab) return "no MainTab"
      mainTab.startNew("note")
      mainTab.editorTitle = title
      return "ok"
    }
    function filterPanel(type: string, query: string): string {
      var mainTab = sr.find(widget.item.panelItem, "MainTab")
      if (!mainTab) return "no MainTab"
      mainTab.filterType = type
      mainTab.searchText = query
      return "ok"
    }
    function panelRows(): int {
      var mainTab = sr.find(widget.item.panelItem, "MainTab")
      return mainTab ? mainTab.itemList.length : -1
    }
    function quit(): void { Qt.exit(0) }
  }
}
QML

OMANOTES_WORKTREE="$worktree" "${qs_cmd[@]}" > "$cfg_dir/qs.log" 2>&1 &
qs_pid=$!
trap 'kill "$qs_pid" 2> /dev/null || true; wait "$qs_pid" 2> /dev/null || true; rm -rf "$cfg_dir" "$data_home"' EXIT

ipc() { qs -p "$cfg_dir" ipc call "$@" 2>&1; }

up=0
for _ in $(seq 50); do
  [[ "$(ipc scratchpad ping)" == "ok" ]] && { up=1; break; }
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

replies "addNote answers ok" "$(ipc scratchpad addNote "IPC-NOTE" "ipc body")" '{"ok":true}'
expect "addNote writes the note" \
  "SELECT type || '|' || body || '|' || status FROM items WHERE title = 'IPC-NOTE'" "note|ipc body|0"
replies "addNote with an empty title is refused" "$(ipc scratchpad addNote "  " "")" '{"ok":false,"error":"title is required"}'

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
replies "toggleTodo again answers ok" "$(ipc scratchpad toggleTodo 2)" '{"ok":true}'
expect "toggleTodo again reopens the completed todo" "SELECT status FROM items WHERE id = 2" "0"
expect "the reopen is logged in history" \
  "SELECT COUNT(*) FROM history WHERE action = 'reopened' AND title = 'Renew the domain'" "1"
replies "toggleTodo on a missing id is refused" "$(ipc scratchpad toggleTodo 999)" '{"ok":false,"error":"item not found: 999"}'

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

replies "clearHistory answers ok" "$(ipc scratchpad clearHistory)" '{"ok":true}'
expect "clearHistory empties history" "SELECT COUNT(*) FROM history" "0"
expect "clearHistory keeps the items" "SELECT COUNT(*) FROM items" "6"

ipc scratchpad open > /dev/null
replies "the open panel takes a draft" "$(ipc omanotes-test typeDraft "DRAFT-ON-CLOSE")" "ok"
ipc scratchpad close > /dev/null
expect "an unsaved draft is saved when the panel closes" \
  "SELECT COUNT(*) FROM items WHERE title = 'DRAFT-ON-CLOSE'" "1"

ipc omanotes-test quit > /dev/null || true
wait "$qs_pid" || true
if grep -q "omanotes db:" "$cfg_dir/qs.log"; then fail "no db failure logged: $(grep -m3 "omanotes db:" "$cfg_dir/qs.log" | tr '\n' ';')"
else pass "no db failure logged"; fi

(( failures == 0 )) || tail -n 40 "$cfg_dir/qs.log"
echo "panel: $checks checks, $failures failed"
exit $(( failures > 0 ))
