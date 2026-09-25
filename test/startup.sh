#!/usr/bin/env bash
# Loads one BarWidget per monitor and the one Service, as the shell does,
# against a missing database file, with the first migration failing as a
# locked database does. Asserts that the IPC refuses calls until the database
# is ready, that list, toggle and remove keep refusing until the first read of
# every item lands, that every widget runs one Db that its panel shares and
# holds no clock or ring window of its own, that every Db ends ready at the
# current schema version while the widgets and the service race to migrate,
# and that one write reloads each Db once, the service's alarm store included.

set -euo pipefail
source "$(dirname "$0")/lib/harness.sh"
stub_keyboard_panel

rm -rf "$data_home/omarchy"
monitors=3

# Logs every sqlite3 run, one line each. Migrations wait for the release
# file, and the first one fails. Reads of every item wait for the
# items-release file.
real_sqlite3="$(command -v sqlite3)"
mkdir "$cfg_dir/bin"
cat > "$cfg_dir/bin/sqlite3" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$cfg_dir/sqlite3.log"
if [[ "\$*" == *"FROM items ORDER BY"* ]]; then
  for _ in \$(seq 200); do [[ -e "$cfg_dir/items-release" ]] && break; sleep 0.05; done
fi
if [[ "\$*" == *"CREATE TABLE"* ]]; then
  for _ in \$(seq 200); do [[ -e "$cfg_dir/release" ]] && break; sleep 0.05; done
  if mkdir "$cfg_dir/init-failed" 2> /dev/null; then
    echo "Error: database is locked" >&2
    exit 5
  fi
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

  function typesIn(obj, prefix, found) {
    if (!obj) return found
    if (String(obj).indexOf(prefix) === 0 && found.indexOf(obj) < 0) found.push(obj)
    var kids = obj.data || []
    for (var i = 0; i < kids.length; ++i) sr.typesIn(kids[i], prefix, found)
    return found
  }
  function dbsIn(obj, found) { return sr.typesIn(obj, "Db", found) }

  // The service, as the shell mounts it: once, with its own clock.
  Loader {
    id: svc
    source: "file://" + Quickshell.env("OMANOTES_WORKTREE") + "/Service.qml"
  }

  Variants {
    id: monitors
    model: [$(seq -s, $monitors)]
    FloatingWindow {
      required property var modelData
      readonly property var widget: loader.item
      implicitWidth: 40; implicitHeight: 40
      Loader {
        id: loader
        anchors.fill: parent
        source: "file://" + Quickshell.env("OMANOTES_WORKTREE") + "/BarWidget.qml"
        onLoaded: item.service = Qt.binding(function() { return svc.item })
      }
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
        var owned = sr.typesIn(w.panelItem, "SystemClock", sr.typesIn(w, "SystemClock", [])).length
          + sr.typesIn(w.panelItem, "RingWindow", sr.typesIn(w, "RingWindow", [])).length
        out.push({ dbs: dbs.length, ready: ready, panelShares: dbs.indexOf(w.panelItem.db) >= 0, clocksAndWindows: owned })
      }
      return JSON.stringify(out)
    }
    function serviceState(): string {
      if (!svc.item) return "none"
      return String(svc.item).split("_QMLTYPE")[0].split("(")[0] + "|" + svc.item.loaded + "|" + sr.dbsIn(svc.item, []).length
    }
    function addNote(title: string): string {
      return monitors.instances[0].widget.ipcAdd("note", title, "")
    }
    function everyCall(): string {
      var w = monitors.instances[0].widget
      return [w.ipcAdd("note", "EARLY", ""), w.ipcToggle(1), w.ipcRemove(1), w.ipcClearHistory(),
        w.ipcList("note"), w.ipcList("todo")].join(" ")
    }
    function readCalls(): string {
      var w = monitors.instances[0].widget
      return [w.ipcToggle(1), w.ipcRemove(1), w.ipcList("note"), w.ipcList("todo")].join(" ")
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

refused='{"ok":false,"error":"not ready"}'
replies "every IPC call before the database is ready answers not ready" "$(ipc everyCall)" \
  "$refused $refused $refused $refused $refused $refused"
touch "$cfg_dir/release"

one='{"dbs":1,"ready":1,"panelShares":true,"clocksAndWindows":0}'
want="[$one$(printf ",$one%.0s" $(seq 2 $monitors))]"
state=""
for _ in $(seq 50); do
  state="$(ipc state)"
  [[ "$state" == "$want" ]] && break
  sleep 0.2
done
replies "each widget runs one Db, shared with its panel and ready, and no clock or ring window" "$state" "$want"
service_state=""
for _ in $(seq 50); do
  service_state="$(ipc serviceState)"
  [[ "$service_state" == "Service|true|1" ]] && break
  sleep 0.2
done
replies "the service runs, loaded, with one alarm store of its own" "$service_state" "Service|true|1"
replies "list, toggle and remove answer not ready until the items are read" "$(ipc readCalls)" \
  "$refused $refused $refused $refused"
touch "$cfg_dir/items-release"
reads=""
for _ in $(seq 50); do
  reads="$(ipc readCalls)"
  [[ "$reads" != "$refused"* ]] && break
  sleep 0.2
done
replies "list, toggle and remove answer from the items once read" "$reads" \
  '{"ok":false,"error":"item not found: 1"} {"ok":false,"error":"item not found: 1"} [] []'

[[ -d "$cfg_dir/init-failed" ]] && pass "the first migration failed" || fail "the first migration failed"
replies "each widget and the service migrated from version 0 once, the one that lost the race included" \
  "$(grep -c "CREATE TABLE" "$cfg_dir/sqlite3.log" || true)" "$(( monitors + 1 ))"
tables="$(sqlite3 "$data_home/omarchy/scratchpad.db" "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('items', 'history', 'alarms') ORDER BY name" 2>&1 | tr '\n' ' ')"
replies "the missing database file now has the three tables" "$tables" "alarms history items "
current="$(node --input-type=module -e '
  const { loadQmlLib } = await import(process.argv[1])
  process.stdout.write(String(loadQmlLib(process.argv[2], ["MIGRATIONS"]).MIGRATIONS.length))
' "$worktree/test/lib/load-qml-lib.mjs" "$worktree/data/Db.js" 2>&1 || true)"
replies "the database is at the current schema version" \
  "$(sqlite3 "$data_home/omarchy/scratchpad.db" "PRAGMA user_version")" "$current"
replies "the refused add never lands" \
  "$(sqlite3 "$data_home/omarchy/scratchpad.db" "SELECT COUNT(*) FROM items WHERE title = 'EARLY'")" "0"

sleep 1
: > "$cfg_dir/sqlite3.log"
replies "addNote answers ok" "$(ipc addNote "ONE-WRITE")" '{"ok":true}'
sleep 1.5
replies "the note reached the database" \
  "$(sqlite3 "$data_home/omarchy/scratchpad.db" "SELECT COUNT(*) FROM items WHERE title = 'ONE-WRITE'")" "1"
replies "one write reloads each Db once" "$(grep -c "FROM history ORDER BY" "$cfg_dir/sqlite3.log" || true)" "$monitors"
replies "and the alarm store once" "$(grep -c "FROM alarms ORDER BY" "$cfg_dir/sqlite3.log" || true)" "1"

ipc quit > /dev/null || true
wait "$qs_pid" || true
replies "only the refused writes and the injected failure are logged" \
  "$(grep -o "omanotes db: .*" "$cfg_dir/qs.log" | sed 's/^omanotes db: //' | tr '\n' ';' || true)" \
  "not ready;not ready;database is locked;"

(( failures == 0 )) || tail -n 40 "$cfg_dir/qs.log"
echo "startup: $checks checks, $failures failed"
exit $(( failures > 0 ))
