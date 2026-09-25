#!/usr/bin/env bash
# Loads one BarWidget per monitor, as the bar does, against a missing database
# file, with the first schema run failing as a locked database does. Asserts
# that every widget runs one Db that its panel shares, that every Db ends
# ready, and that one write reloads each Db once.

set -euo pipefail
source "$(dirname "$0")/lib/harness.sh"
stub_keyboard_panel

rm -rf "$data_home/omarchy"
monitors=3

# Logs every sqlite3 run, one line each, and fails the first schema run.
real_sqlite3="$(command -v sqlite3)"
mkdir "$cfg_dir/bin"
cat > "$cfg_dir/bin/sqlite3" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$cfg_dir/sqlite3.log"
if [[ "\$*" == *"CREATE TABLE"* ]] && mkdir "$cfg_dir/init-failed" 2> /dev/null; then
  echo "Error: database is locked" >&2
  exit 5
fi
exec "$real_sqlite3" "\$@"
SH
chmod +x "$cfg_dir/bin/sqlite3"

cat > "$cfg_dir/shell.qml" <<QML
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: sr

  function dbsIn(obj, found) {
    if (!obj) return found
    if (String(obj).indexOf("Db") === 0 && found.indexOf(obj) < 0) found.push(obj)
    var kids = obj.data || []
    for (var i = 0; i < kids.length; ++i) sr.dbsIn(kids[i], found)
    return found
  }

  Variants {
    id: monitors
    model: [$(seq -s, $monitors)]
    FloatingWindow {
      required property var modelData
      readonly property var widget: loader.item
      implicitWidth: 40; implicitHeight: 40
      Loader { id: loader; anchors.fill: parent; source: "file://" + Quickshell.env("OMANOTES_WORKTREE") + "/BarWidget.qml" }
    }
  }

  IpcHandler {
    target: "omanotes-test"
    function ping(): string { return "ok" }
    function state(): string {
      var out = []
      for (var i = 0; i < monitors.instances.length; ++i) {
        var w = monitors.instances[i].widget
        var dbs = sr.dbsIn(w.panelItem, sr.dbsIn(w, []))
        var ready = 0
        for (var j = 0; j < dbs.length; ++j) if (dbs[j].ready) ready++
        out.push({ dbs: dbs.length, ready: ready, panelShares: dbs.indexOf(w.panelItem.db) >= 0 })
      }
      return JSON.stringify(out)
    }
    function addNote(title: string): string {
      return monitors.instances[0].widget.ipcAdd("note", title, "")
    }
    function quit(): void { Qt.exit(0) }
  }
}
QML

PATH="$cfg_dir/bin:$PATH" OMANOTES_WORKTREE="$worktree" "${qs_cmd[@]}" > "$cfg_dir/qs.log" 2>&1 &
qs_pid=$!
trap 'kill "$qs_pid" 2> /dev/null || true; wait "$qs_pid" 2> /dev/null || true; rm -rf "$cfg_dir" "$data_home"' EXIT

ipc() { qs -p "$cfg_dir" ipc call omanotes-test "$@" 2>&1; }

up=0
for _ in $(seq 50); do
  [[ "$(ipc ping)" == "ok" ]] && { up=1; break; }
  sleep 0.2
done
if (( ! up )); then cat "$cfg_dir/qs.log"; echo "the test shell never answered ping"; exit 2; fi

checks=0
failures=0
pass() { checks=$((checks + 1)); echo "ok   $1"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); echo "FAIL $1"; }
replies() {
  local what="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then pass "$what"; else fail "$what: want '$want', got '$got'"; fi
}

one='{"dbs":1,"ready":1,"panelShares":true}'
want="[$one$(printf ",$one%.0s" $(seq 2 $monitors))]"
state=""
for _ in $(seq 50); do
  state="$(ipc state)"
  [[ "$state" == "$want" ]] && break
  sleep 0.2
done
replies "each widget runs one Db, shared with its panel and ready" "$state" "$want"

[[ -d "$cfg_dir/init-failed" ]] && pass "the first schema run failed" || fail "the first schema run failed"
tables="$(sqlite3 "$data_home/omarchy/scratchpad.db" "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('items', 'history') ORDER BY name" 2>&1 | tr '\n' ' ')"
replies "the missing database file now has both tables" "$tables" "history items "

sleep 1
: > "$cfg_dir/sqlite3.log"
replies "addNote answers ok" "$(ipc addNote "ONE-WRITE")" '{"ok":true}'
sleep 1.5
replies "the note reached the database" \
  "$(sqlite3 "$data_home/omarchy/scratchpad.db" "SELECT COUNT(*) FROM items WHERE title = 'ONE-WRITE'")" "1"
replies "one write reloads each Db once" "$(grep -c "FROM history ORDER BY" "$cfg_dir/sqlite3.log" || true)" "$monitors"

ipc quit > /dev/null || true
wait "$qs_pid" || true
replies "only the injected failure is logged" "$(grep -c "omanotes db:" "$cfg_dir/qs.log" || true)" "1"

(( failures == 0 )) || tail -n 40 "$cfg_dir/qs.log"
echo "startup: $checks checks, $failures failed"
exit $(( failures > 0 ))
