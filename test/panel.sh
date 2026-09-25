#!/usr/bin/env bash
# Loads the real BarWidget, and the Panel it owns, against a seeded sqlite db,
# offscreen. Drives it through `qs ipc call` the way a script or keybind does,
# then asserts the JSON replies and the rows that reached the db.

set -euo pipefail
source "$(dirname "$0")/lib/harness.sh"

# The kit's KeyboardPanel is a layer-shell PanelWindow, which has no backend
# offscreen, so the Panel would fail to load. Swap in a plain window with the
# API Panel.qml uses; the rest of the kit stays the installed one.
rm "$cfg_dir/Ui"
mkdir "$cfg_dir/Ui"
ln -s "$shell_root"/Ui/* "$cfg_dir/Ui/"
rm "$cfg_dir/Ui/KeyboardPanel.qml"
cat > "$cfg_dir/Ui/KeyboardPanel.qml" <<'QML'
import QtQuick
import Quickshell

FloatingWindow {
  required property Item anchorItem
  required property QtObject bar
  property var owner: null
  property bool open: false
  property int contentWidth
  property int contentHeight
  default property alias contentItem: holder.children
  function fittedContentWidth(width) { return width }
  function fittedContentHeight(height) { return height }
  visible: open
  implicitWidth: contentWidth
  implicitHeight: contentHeight
  Item { id: holder; anchors.fill: parent }
}
QML

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
    function quit(): void { Qt.exit(0) }
  }
}
QML

OMANOTES_WORKTREE="$worktree" run_qs > "$cfg_dir/qs.log" 2>&1 &
qs_pid=$!
trap 'kill "$qs_pid" 2> /dev/null || true; rm -rf "$cfg_dir" "$data_home"' EXIT

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
replies "listNotes returns every note with its fields" "$(by_id "$listed")" \
  "$(by_id "$(sqlite3 "$db" "SELECT json_group_array(json_object('id', id, 'type', type, 'title', title, 'body', COALESCE(body, ''), 'status', status)) FROM items WHERE type = 'note'")")"

replies "toggleTodo answers ok" "$(ipc scratchpad toggleTodo 2)" '{"ok":true}'
expect "toggleTodo completes the pending todo" "SELECT status FROM items WHERE id = 2" "1"
expect "toggleTodo is logged in history" \
  "SELECT COUNT(*) FROM history WHERE action = 'completed' AND title = 'Renew the domain'" "1"
replies "toggleTodo on a missing id is refused" "$(ipc scratchpad toggleTodo 999)" '{"ok":false,"error":"item not found: 999"}'

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
