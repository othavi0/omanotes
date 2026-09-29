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
  function panelDb(n) { return monitors.instances[n].widget.panelItem.db }

  property string lastFailure: ""
  Connections {
    target: monitors.instances.length > 0 && monitors.instances[0].widget && monitors.instances[0].widget.panelItem
      ? monitors.instances[0].widget.panelItem.db : null
    function onWriteFailed(kind, args, message) { sr.lastFailure = kind + ":" + message }
  }

  // False destroys the service and every widget, as a plugin reload does.
  property bool pluginOn: true
  // The one Store, kept from stores() so the test still reaches it with no view.
  property var store: null
  property string spoofed: ""

  Loader {
    id: svc
    active: sr.pluginOn
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
        active: sr.pluginOn
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
    // The Store every view talks to, counted by identity.
    function stores(): string {
      var views = sr.dbsIn(svc.item, [])
      for (var i = 0; i < monitors.instances.length; ++i) views = views.concat(sr.dbsIn(monitors.instances[i].widget, []))
      var found = []
      for (var j = 0; j < views.length; ++j) if (found.indexOf(views[j]._store.target) < 0) found.push(views[j]._store.target)
      if (found.length > 0) sr.store = found[0]
      return JSON.stringify({ views: views.length, stores: found.length })
    }
    // What the Store holds: rows, and the text the lanes' collectors keep.
    function storeState(): string {
      var s = sr.store
      var held = [s.writeLane, s.readLane].map(function(l) { return l.stdout ? l.stdout.text.length : 0 })
      return JSON.stringify({ ready: s.ready, items: s.allItems.length, history: s.history.length, alarms: s.alarms.length, held: held[0] + held[1] })
    }
    // An add, then the plugin goes away in the same tick, before the write is sent.
    function addThenOff(title: string): string {
      var queued = sr.panelDb(0).add("note", title, "")
      sr.pluginOn = false
      return queued
    }
    function setSpawnLimit(ms: int): void { sr.store.spawnLimitMs = ms }
    function setWatcherDelay(ms: int): void { sr.store.reloadDebounce.interval = ms }
    // A widget's view sending the service's write, as any QML of the plugin could.
    function spoof(): string {
      var db = sr.panelDb(0)
      sr.spoofed = "pending"
      sr.store.write(db._key, "alarm.delete", { id: 1 }, function(r) { sr.spoofed = r.ok ? "ok" : r.err })
      return "sent"
    }
    function spoofed(): string { return sr.spoofed }
    // Every panel asks for a reload at once, as opening them would.
    function loadAll(): void {
      for (var i = 0; i < monitors.instances.length; ++i) sr.panelDb(i).load()
    }
    function addBody(title: string, size: int): string {
      return monitors.instances[0].widget.ipcAdd("note", title, "x".repeat(size))
    }
    // An add from the panel, which hears a failure as its user's.
    function addFromPanel(title: string, size: int): string {
      return sr.panelDb(0).add("note", title, "x".repeat(size))
    }
    function lastFailure(): string { return sr.lastFailure }
    function setPlugin(on: bool): void { sr.pluginOn = on }
    function loaded(): int {
      var n = svc.item ? 1 : 0
      for (var i = 0; i < monitors.instances.length; ++i) if (monitors.instances[i].widget && monitors.instances[i].widget.panelItem) n++
      return n
    }
    // How many widgets list an item with this title.
    function seen(title: string): int {
      var n = 0
      for (var i = 0; i < monitors.instances.length; ++i) {
        if (sr.panelDb(i).allItems.some(function(item) { return item.title === title })) n++
      }
      return n
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
replies "the migration the binary ran on the new file is in the journal, once" \
  "$(grep -c "omanotes-db: migrated 0 -> $current" "$cfg_dir/qs.log" || true)" "1"

sleep 1
: > "$cfg_dir/db.log"
replies "addNote answers ok" "$(ipc addNote "ONE-WRITE")" '{"ok":true}'
sleep 1.5
replies "the note reached the database" \
  "$(sqlite3 "$data_home/omarchy/scratchpad.db" "SELECT COUNT(*) FROM items WHERE title = 'ONE-WRITE'")" "1"
# The requests db.log holds, each as its kinds: "sync" or "write write:<op>...".
requests() { cut -d' ' -f2- "$cfg_dir/db.log" | sed 's/ {.*//' | tr '\n' ';'; }
file="$data_home/omarchy/scratchpad.db"
count() { sqlite3 "$file" "SELECT COUNT(*) FROM items WHERE title = '$1'"; }
wait_for_count() {
  for _ in $(seq 50); do [[ "$(count "$1")" == "$2" ]] && return; sleep 0.1; done
}
replies "one write is one request that carries it and the snapshot after it, then one read the watcher asks for" \
  "$(requests)" "write write:item.add;sync;"

replies "the three widgets and the service talk to one Store" "$(ipc stores)" '{"views":4,"stores":1}'

sleep 1
: > "$cfg_dir/db.log"
sqlite3 "$file" "INSERT INTO items (type, title, status, created_at, updated_at) VALUES ('note', 'OUTSIDE', 0, 1, 1)"
seen=""
for _ in $(seq 30); do
  seen="$(ipc seen OUTSIDE)"
  [[ "$seen" == "$monitors" ]] && break
  sleep 0.1
done
replies "every widget lists the note written outside" "$seen" "$monitors"
sleep 1
replies "a write from outside reloads the three widgets and the service with one request" "$(requests)" "sync;"
: > "$cfg_dir/db.log"
ipc loadAll > /dev/null
sleep 1
replies "every panel asking for a reload at once is one request" "$(requests)" "sync;"
replies "the lanes keep no text of an answer once it is read" "$(ipc storeState | grep -o '"held":[0-9]*')" '"held":0'

: > "$cfg_dir/db.log"
replies "a body of 70 000 characters is queued" "$(ipc addBody BODY-70000 70000)" '{"ok":true}'
wait_for_count BODY-70000 1
replies "and saved whole" "$(sqlite3 "$file" "SELECT length(body) FROM items WHERE title = 'BODY-70000'")" "70000"
replies "a body over the request cap is refused before a spawn and given back to the panel" \
  "$(ipc addFromPanel HUGE 1100000)|$(ipc lastFailure)|$(count HUGE)" "|add:text too large to save|0"

touch "$cfg_dir/hold-sync"
ipc loadAll > /dev/null
probe="run $file"
held=""
for _ in $(seq 30); do
  held="$(pgrep -f "$probe" | wc -l)"
  (( held > 0 )) && break
  sleep 0.1
done
replies "a request held open is a process the probe sees" "$(( held > 0 ))" "1"
rm -f "$cfg_dir/hold-sync"
sleep 1
replies "no omanotes-db process outlives the requests" "$(pgrep -af "$probe" || true)" ""
logged_so_far="$(grep -o "omanotes db: .*" "$cfg_dir/qs.log" | sed 's/^omanotes db: //' | tr '\n' ';' || true)"

mv "$cfg_dir/bin/omanotes-db.$arch" "$cfg_dir/bin/away"
replies "an add while the binary is missing is queued" "$(ipc addFromPanel LOST 1)" ""
failure=""
for _ in $(seq 30); do
  failure="$(ipc lastFailure)"
  [[ "$failure" == "add:cannot run"* ]] && break
  sleep 0.1
done
mv "$cfg_dir/bin/away" "$cfg_dir/bin/omanotes-db.$arch"
replies "and fails in the panel, naming the file that did not start" "$failure" "add:cannot run the database helper $stub_tree/bin/omanotes-db.$arch"
replies "the queue moves on once the binary is back" "$(ipc addNote AFTER)" '{"ok":true}'
wait_for_count AFTER 1
replies "the next write lands and the failed one was not sent again" "$(count AFTER)|$(count LOST)" "1|0"

sleep 1
ipc setSpawnLimit 1000 > /dev/null
touch "$cfg_dir/hold-sync"
ipc loadAll > /dev/null
killed=0
for _ in $(seq 40); do
  grep -q "omanotes db: read failed: the database helper stopped without an answer" "$cfg_dir/qs.log" && { killed=1; break; }
  sleep 0.1
done
replies "a spawn that outlives its limit is killed, and its read fails as a crash" "$killed" "1"
rm -f "$cfg_dir/hold-sync"
ipc setSpawnLimit 30000 > /dev/null
sleep 1.5
replies "and no omanotes-db process is left behind" "$(pgrep -af "$probe" || true)" ""

sleep 1
replies "an add made as the plugin goes away is queued" "$(ipc addThenOff LATE)" ""
gone=""
for _ in $(seq 30); do
  gone="$(ipc loaded)"
  [[ "$gone" == 0 ]] && break
  sleep 0.1
done
replies "the service and the widgets go away, as in a plugin reload" "$gone" "0"
wait_for_count LATE 1
replies "and the write goes out with no view left: it was accepted" "$(count LATE)" "1"
replies "with no view the Store holds no rows and the lanes no text" "$(ipc storeState)" \
  '{"ready":false,"items":0,"history":0,"alarms":0,"held":0}'
: > "$cfg_dir/db.log"
sqlite3 "$file" "INSERT INTO items (type, title, status, created_at, updated_at) VALUES ('note', 'WHILE-DOWN', 0, 1, 1)"
sleep 1
replies "with no view the Store spawns nothing, even when the file changes" "$(requests)" ""
ipc setPlugin true > /dev/null
seen=""
for _ in $(seq 50); do
  seen="$(ipc seen WHILE-DOWN 2> /dev/null)"
  [[ "$seen" == "$monitors" ]] && break
  sleep 0.1
done
replies "the widgets that come back list what changed while nothing watched" "$seen" "$monitors"
replies "and they talk to the same one Store" "$(ipc stores)" '{"views":4,"stores":1}'

ipc quit > /dev/null || true
wait "$qs_pid" || true
replies "only the refused writes and the injected failures are logged" \
  "$logged_so_far" "not ready;not ready;database is locked;text too large to save;"
replies "and the missing binary is in the journal" \
  "$(grep -c "omanotes db: cannot run the database helper $stub_tree/bin/omanotes-db.$arch" "$cfg_dir/qs.log" || true)" "1"

(( failures == 0 )) || tail -n 40 "$cfg_dir/qs.log"
echo "startup: $checks checks, $failures failed"
exit $(( failures > 0 ))
