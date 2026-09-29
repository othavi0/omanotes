#!/usr/bin/env bash
# Loads one BarWidget per monitor and the one Service, as the shell does,
# against a missing database file, with the first request failing as a locked
# database does. Asserts that the IPC refuses calls until the first snapshot
# lands, that every widget runs one Db that its panel shares and holds no
# clock or ring window of its own, that the file ends at the current schema
# version, and that start-up and a write each cost one request of the one
# Store, whatever the number of monitors.

set -euo pipefail
source "$(dirname "$0")/lib/harness.sh"
stub_keyboard_panel

rm -rf "$data_home/omarchy"
monitors=3

# The binary is a stub (lib/stub-db.sh) that logs every request, one line each
# in db.log. Requests wait for hold-sync, and the first one fails as a locked
# database does.
stub_db
touch "$cfg_dir/hold-sync" "$cfg_dir/first-fails"

cat > "$cfg_dir/shell.qml" <<QML
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: sr

  function typesIn(obj, prefix, found) {
    if (!obj) return found
    if ([].concat(prefix).some(function(p) { return String(obj).indexOf(p) === 0 }) && found.indexOf(obj) < 0) found.push(obj)
    var kids = obj.data || []
    for (var i = 0; i < kids.length; ++i) sr.typesIn(kids[i], prefix, found)
    return found
  }
  function dbsIn(obj, found) { return sr.typesIn(obj, ["ItemsDb", "AlarmsDb"], found) }

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

PATH="$cfg_dir/bin:$PATH" OMANOTES_WORKTREE="$stub_tree" "${qs_cmd[@]}" > "$cfg_dir/qs.log" 2>&1 &
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
rm -f "$cfg_dir/hold-sync"

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
reads=""
for _ in $(seq 50); do
  reads="$(ipc readCalls)"
  [[ "$reads" != "$refused"* ]] && break
  sleep 0.2
done
replies "list, toggle and remove answer from the items once read" "$reads" \
  '{"ok":false,"error":"item not found: 1"} {"ok":false,"error":"item not found: 1"} [] []'

replies "the first request failed as a locked database and the Store asked again: two requests, not one per widget" \
  "$(wc -l < "$cfg_dir/db.log")" "2"
replies "and the one that lost is the only one that carried no migration to report" \
  "$(grep -c '"writes"' "$cfg_dir/db.log" || true)" "0"
tables="$(sqlite3 "$data_home/omarchy/scratchpad.db" "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('items', 'history', 'alarms') ORDER BY name" 2>&1 | tr '\n' ' ')"
replies "the missing database file now has the three tables" "$tables" "alarms history items "
current="$("$real_db" "$protocol" version | sed -n 's/.*"schema":\([0-9]*\).*/\1/p')"
replies "the database is at the current schema version" \
  "$(sqlite3 "$data_home/omarchy/scratchpad.db" "PRAGMA user_version")" "$current"
replies "the refused add never lands" \
  "$(sqlite3 "$data_home/omarchy/scratchpad.db" "SELECT COUNT(*) FROM items WHERE title = 'EARLY'")" "0"

sleep 1
: > "$cfg_dir/db.log"
replies "addNote answers ok" "$(ipc addNote "ONE-WRITE")" '{"ok":true}'
sleep 1.5
replies "the note reached the database" \
  "$(sqlite3 "$data_home/omarchy/scratchpad.db" "SELECT COUNT(*) FROM items WHERE title = 'ONE-WRITE'")" "1"
replies "one write is one request that carries it, whatever the number of monitors" "$(grep -c 'write:item.add' "$cfg_dir/db.log" || true)" "1"
replies "and everything after it, the reload of every monitor and of the alarm store included, is at most one more request" \
  "$(( $(wc -l < "$cfg_dir/db.log") <= 2 ? 1 : 0 ))" "1"

ipc quit > /dev/null || true
wait "$qs_pid" || true
replies "only the refused writes and the injected failure are logged" \
  "$(grep -o "omanotes db: .*" "$cfg_dir/qs.log" | sed 's/^omanotes db: //' | tr '\n' ';' || true)" \
  "not ready;not ready;database is locked;"

(( failures == 0 )) || tail -n 40 "$cfg_dir/qs.log"
echo "startup: $checks checks, $failures failed"
exit $(( failures > 0 ))
