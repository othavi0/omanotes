#!/usr/bin/env bash
# Loads the real BarWidget, and the Panel it owns, against a seeded sqlite db,
# offscreen. Drives it through `qs ipc call` the way a script or keybind does,
# then asserts the JSON replies and the rows that reached the db.

set -euo pipefail
source "$(dirname "$0")/lib/harness.sh"
stub_keyboard_panel

# While the hold file exists, a read runs at once but prints only when the
# release file appears, so the test can write and reload in between. A held
# list read of todos with a search fails while the fail-list file exists.
real_sqlite3="$(command -v sqlite3)"
mkdir "$cfg_dir/bin"
cat > "$cfg_dir/bin/sqlite3" <<SH
#!/usr/bin/env bash
[[ "\$*" == *-json* && -e "$cfg_dir/hold" ]] || exec "$real_sqlite3" "\$@"
fail=0
[[ -e "$cfg_dir/fail-list" && "\$*" == *"WHERE type = 'todo' AND (search_title LIKE"* ]] && fail=1
out="\$("$real_sqlite3" "\$@" 2>&1)"
code=\$?
printf '%s\n' "\$*" >> "$cfg_dir/held.log"
for _ in \$(seq 200); do [[ -e "$cfg_dir/release" ]] && break; sleep 0.05; done
if (( fail )); then echo "Error: disk I/O error" >&2; exit 10; fi
printf '%s' "\$out"
exit \$code
SH
chmod +x "$cfg_dir/bin/sqlite3"

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
    function editItem(id: int, title: string): string {
      var mainTab = sr.find(widget.item.panelItem, "MainTab")
      if (!mainTab) return "no MainTab"
      mainTab.pickItem(id)
      mainTab.editorTitle = title
      mainTab.toast.text = ""
      return "ok"
    }
    function editorState(): string {
      var mainTab = sr.find(widget.item.panelItem, "MainTab")
      if (!mainTab) return "no MainTab"
      return mainTab.selectedId + "|" + mainTab.editorTitle + "|toast:" + mainTab.toast.text
    }
    // Writes as the panel's user makes them, so a failure reaches the toast.
    function userWrite(method: string, id: string): string {
      var mainTab = sr.find(widget.item.panelItem, "MainTab")
      if (!mainTab) return "no MainTab"
      mainTab.toast.text = ""
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
    function toast(): string {
      var mainTab = sr.find(widget.item.panelItem, "MainTab")
      return mainTab ? mainTab.toast.text : "no MainTab"
    }
    function quit(): void { Qt.exit(0) }
  }
}
QML

PATH="$cfg_dir/bin:$PATH" OMANOTES_WORKTREE="$worktree" "${qs_cmd[@]}" > "$cfg_dir/qs.log" 2>&1 &
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

replies "addNote answers ok" "$(ipc scratchpad addNote "IPC-NOTE" "ipc body")" '{"ok":true}'
expect "addNote writes the note" \
  "SELECT type || '|' || body || '|' || status FROM items WHERE title = 'IPC-NOTE'" "note|ipc body|0"
replies "addNote with an empty title is refused" "$(ipc scratchpad addNote "  " "")" '{"ok":false,"error":"title is required"}'
replies "addTodo answers ok" "$(ipc scratchpad addTodo "IPC-TODO" "todo body")" '{"ok":true}'
expect "addTodo writes the todo" \
  "SELECT type || '|' || body || '|' || status FROM items WHERE title = 'IPC-TODO'" "todo|todo body|0"
replies "addTodo with an empty title is refused" "$(ipc scratchpad addTodo "" "")" '{"ok":false,"error":"title is required"}'

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
hold_reads() { rm -f "$cfg_dir/release"; : > "$cfg_dir/held.log"; touch "$cfg_dir/hold"; }
release_reads() { rm -f "$cfg_dir/hold" "$cfg_dir/fail-list"; touch "$cfg_dir/release"; }
all_reads_held() {
  for _ in $(seq 50); do
    (( $(wc -l < "$cfg_dir/held.log") >= 4 )) && { pass "$1"; return; }
    sleep 0.2
  done
  fail "$1: held $(wc -l < "$cfg_dir/held.log") of 4 reads"
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
all_reads_held "the reload after the first write holds its four reads"
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
all_reads_held "the reload after the third write holds its four reads"
ipc omanotes-test filterPanel note coffee > /dev/null
sleep 0.5
release_reads
panel_rows_are "a failed list read re-runs with the latest filter and search" 1
ipc omanotes-test filterPanel all "" > /dev/null

ipc omanotes-test quit > /dev/null || true
wait "$qs_pid" || true
replies "only the failure cases are logged" "$(logged_failures)" \
  "item not found;item not found;item not found;item not found;invalid id: abc;database is locked;list read failed: disk I/O error;"

(( failures == 0 )) || tail -n 40 "$cfg_dir/qs.log"
echo "panel: $checks checks, $failures failed"
exit $(( failures > 0 ))
