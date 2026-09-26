#!/usr/bin/env bash
# Drives the real Service.qml offscreen with its clock off, against a seeded
# sqlite db, three stand-in screens and the real RingCard inside a plain
# window. Stubs in PATH take the player, the notification and sqlite3, so the
# test can hold a read across a tick, hold or fail the writes, and count what
# the sound and the notification were asked to do. Asserts the ring, the
# missed notification, the overlay under a stale read, snooze, stop, the
# three automatic snoozes, the sound latch and an outside change dropping the
# card. Every instant is driven through tick(ms), in a fixed time zone.

set -euo pipefail
export TZ=America/Sao_Paulo
source "$(dirname "$0")/lib/harness.sh"
stub_keyboard_panel

day="$(date +%F)"
ms() { echo $(( $(date -d "$1" +%s) * 1000 )); }
yesterday="$(ms "$day 12:00 1 day ago")"
today_name="$(date +%a)"
tomorrow_name="$(date -d "$day 1 day" +%a)"
sound_file="$cfg_dir/alarm.oga"
: > "$sound_file"

real_sqlite3="$(command -v sqlite3)"
mkdir "$cfg_dir/bin"
cat > "$cfg_dir/bin/sqlite3" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$cfg_dir/sqlite3.log"
if [[ "\$*" == *"UPDATE alarms"* ]]; then
  for _ in \$(seq 400); do [[ -e "$cfg_dir/hold-writes" ]] || break; sleep 0.05; done
  if [[ -e "$cfg_dir/fail-writes" ]]; then echo "Error: disk I/O error" >&2; exit 10; fi
fi
if [[ "\$*" == *"INSERT INTO alarms"* ]]; then
  for _ in \$(seq 400); do [[ -e "$cfg_dir/hold-inserts" ]] || break; sleep 0.05; done
  if [[ -e "$cfg_dir/fail-insert" ]]; then echo "Error: disk I/O error" >&2; exit 10; fi
fi
if [[ "\$*" == *"FROM alarms ORDER BY"* && -e "$cfg_dir/hold-reads" ]]; then
  out="\$("$real_sqlite3" "\$@" 2>&1)"
  code=\$?
  for _ in \$(seq 400); do [[ -e "$cfg_dir/hold-reads" ]] || break; sleep 0.05; done
  printf '%s' "\$out"
  exit \$code
fi
exec "$real_sqlite3" "\$@"
SH
# The player logs its start and its end on TERM, and fails at once while
# sound-fails exists.
cat > "$cfg_dir/bin/pw-play" <<SH
#!/usr/bin/env bash
if [[ -e "$cfg_dir/sound-fails" ]]; then echo "fail \$\$" >> "$cfg_dir/sound.log"; exit 1; fi
echo "start \$\$" >> "$cfg_dir/sound.log"
trap 'echo "end \$\$" >> "$cfg_dir/sound.log"; exit 0' TERM
sleep 30 &
wait \$!
SH
cat > "$cfg_dir/bin/omarchy-notification-send" <<SH
#!/usr/bin/env bash
printf '%s' "\$*" | tr '\n' '/' >> "$cfg_dir/notify.log"
echo >> "$cfg_dir/notify.log"
SH
chmod +x "$cfg_dir/bin/"*
: > "$cfg_dir/sound.log"
: > "$cfg_dir/notify.log"

sqlite3 -cmd ".timeout 5000" "$db" "INSERT INTO alarms (id, hour, minute, label, days, enabled, armed_at_ms) VALUES
  (1, 7, 30, 'Wake up', 127, 1, $yesterday),
  (2, 6, 0, 'Pills', 0, 1, $yesterday),
  (3, 6, 10, 'Standup', 0, 1, $yesterday),
  (4, 7, 30, 'Off', 0, 0, $yesterday);"

cat > "$cfg_dir/shell.qml" <<'QML'
import QtQuick
import Quickshell
import Quickshell.Io
import "ui" as Ui
import "ui/Icons.js" as Icons
import "ui/Tabs.js" as Tabs

ShellRoot {
  id: sr
  property var cards: []

  Variants {
    id: monitors
    model: [1, 2, 3]
    FloatingWindow {
      required property var modelData
      readonly property var widget: loader.item
      implicitWidth: 120; implicitHeight: 40
      Loader {
        id: loader
        anchors.fill: parent
        source: "file://" + Quickshell.env("OMANOTES_WORKTREE") + "/BarWidget.qml"
        // Bound, as the shell's serviceFor is: the service can load after the widget.
        onLoaded: item.service = Qt.binding(function() { return svc.item })
      }
    }
  }

  Component {
    id: stubRing
    FloatingWindow {
      id: win
      required property var modelData
      // Handed by the service, as the shipped window is.
      property QtObject service: null
      implicitWidth: 400
      implicitHeight: 220
      Ui.RingCard { service: win.service }
      Component.onCompleted: sr.cards = sr.cards.concat([win])
      Component.onDestruction: sr.cards = sr.cards.filter(function(w) { return w !== win })
    }
  }

  Loader {
    id: svc
    Component.onCompleted: setSource("file://" + Quickshell.env("OMANOTES_WORKTREE") + "/Service.qml",
      { clockRunning: false, screens: [1, 2, 3], ringWindow: stubRing, soundFile: Quickshell.env("SOUND") })
  }

  function find(obj, typeName, out) {
    out = out || []
    if (!obj) return out
    if (String(obj).indexOf(typeName) === 0) out.push(obj)
    var kids = obj.data || []
    for (var i = 0; i < kids.length; ++i) sr.find(kids[i], typeName, out)
    return out
  }

  function state() {
    var s = svc.item
    var ring = s.ringing ? s.ringing.events.map(function(e) { return e.id }) : []
    return JSON.stringify({ loaded: s.loaded, alarms: s.alarms.length, ringing: ring, cards: sr.cards.length,
      soundBroken: s.soundBroken, title: s.ringTitle, bar: s.barLabel, snooze: s.nextIsSnooze, on: s.onCount })
  }

  function chip(n) {
    return sr.find(monitors.instances[n - 1].widget, "WidgetButton")[0]
  }
  function alarmsTab(n) {
    return sr.find(monitors.instances[(n || 1) - 1].widget.panelItem, "AlarmsTab")[0]
  }
  function editor() {
    return sr.find(sr.alarmsTab(), "AlarmEditor")[0]
  }
  function editorState(n) {
    var tab = sr.alarmsTab(n)
    var editor = sr.find(tab, "AlarmEditor")[0]
    var del = sr.find(editor, "ActionButton").filter(function(b) { return b.visible && (b.text === "Delete" || b.text === "Confirm") })
    return tab.selectedId + "|draft:" + tab.draftNew + "|" + editor.timeText + "|" + (del.length ? del[0].text : "-") + "|toast:" + tab.toast.text
  }
  function chips() {
    var out = []
    for (var i = 1; i <= 3; ++i) {
      var b = sr.chip(i)
      out.push(b.text.replace(Icons.noteFilled, "{note}").replace(Icons.bell, "{bell}").replace(Icons.alarm, "{alarm}")
        .replace(Icons.snooze, "{snooze}") + (b.active ? "*" : ""))
    }
    return out.join("|")
  }

  IpcHandler {
    target: "omanotes-test"
    function ping(): string { return svc.item && monitors.instances.length === 3 && monitors.instances[2].widget ? "ok" : "loading" }
    function tick(ms: string): string { svc.item.tick(Number(ms)); return sr.state() }
    function state(): string { return sr.state() }
    function chips(): string { return sr.chips() }
    function tooltip(n: int): string { return sr.chip(n).tooltipText }
    function pressChip(n: int, button: string): string {
      sr.chip(n).triggerPress(button === "right" ? Qt.RightButton : Qt.LeftButton)
      return sr.chips() + " open=" + monitors.instances[n - 1].widget.opened
    }
    function closePanel(n: int): void { monitors.instances[n - 1].widget.close() }
    function openPanel(n: int): string { monitors.instances[n - 1].widget.open(); return "open=" + monitors.instances[n - 1].widget.opened }
    function setTab(n: int, tab: string): string {
      monitors.instances[n - 1].widget.panelItem.activeTab = Tabs[tab]
      return sr.editorState(n)
    }
    function tabState(n: int): string { return sr.editorState(n) }
    function clearToastOf(n: int): void { sr.alarmsTab(n).toast.text = "" }
    function scrollAlarms(n: int, y: int): string {
      var list = sr.find(sr.alarmsTab(n), "QQuickListView")[0]
      list.contentY = list.originY + y
      return String(list.contentY - list.originY)
    }
    function alarmsScroll(n: int): string {
      var list = sr.find(sr.alarmsTab(n), "QQuickListView")[0]
      return String(list.contentY - list.originY)
    }
    function toggleDay(day: int): string { sr.editor().toggleDay(day); return sr.editorState(1) + "|dirty:" + sr.editor().dirty }
    function itemsState(): string {
      var w = monitors.instances[0].widget
      var itemsTab = sr.find(w.panelItem, "ItemsTab")[0]
      return w.panelItem.db.items.length + "|" + w.panelItem.db.totalHistory + "|toast:" + itemsTab.toast.text
    }
    function openAlarms(): string {
      var w = monitors.instances[0].widget
      w.open()
      w.panelItem.activeTab = Tabs.alarms
      return sr.alarmsTab() ? "ok" : "no AlarmsTab"
    }
    function startNew(): string { sr.alarmsTab().startNew(); return sr.editorState(1) }
    function setEditor(time: string, label: string, days: string, snooze: string, ring: string): string {
      var editor = sr.editor()
      editor.timeText = time
      editor.labelText = label
      editor.days = days === "" ? [] : days.split(",").map(Number)
      editor.snoozeText = snooze
      editor.ringText = ring
      return sr.editorState(1)
    }
    function leave(): string { sr.alarmsTab().commitIfDirty(); return sr.editorState(1) }
    function pickAlarm(id: int): string { sr.alarmsTab().pickAlarm(id); return sr.editorState(1) }
    function toggleRow(id: int): string { sr.alarmsTab().toggleAlarm(id); return sr.editorState(1) }
    function pressDelete(): string { sr.alarmsTab().armDelete(); return sr.editorState(1) }
    function discard(): string { sr.alarmsTab().discardEditor(); return sr.editorState(1) }
    function clearToast(): void { sr.alarmsTab().toast.text = "" }
    function editorState(): string { return sr.editorState(1) }
    function click(n: int, label: string): string {
      var win = sr.cards[n - 1]
      if (!win) return "no card " + n
      var buttons = sr.find(win, "ActionButton").filter(function(b) { return b.text.indexOf(label) === 0 })
      if (buttons.length !== 1) return "found " + buttons.length + " buttons for " + label
      buttons[0].clicked()
      return sr.state()
    }
    function cardText(n: int): string {
      var win = sr.cards[n - 1]
      if (!win) return "no card " + n
      return sr.find(win, "QQuickText").map(function(t) { return t.text }).join("|")
    }
    function quit(): void { Qt.exit(0) }
  }
}
QML

touch "$cfg_dir/hold-reads"
PATH="$cfg_dir/bin:$PATH" OMANOTES_WORKTREE="$worktree" SOUND="$sound_file" "${qs_cmd[@]}" > "$cfg_dir/qs.log" 2>&1 &
qs_pid=$!
trap 'kill "$qs_pid" 2> /dev/null || true; wait "$qs_pid" 2> /dev/null || true; rm -rf "$cfg_dir" "$data_home"' EXIT

ipc() { qs -p "$cfg_dir" ipc call omanotes-test "$@" 2>&1; }

up=0
for _ in $(seq 50); do
  [[ "$(ipc ping)" == "ok" ]] && { up=1; break; }
  sleep 0.2
done
if (( ! up )); then cat "$cfg_dir/qs.log"; echo "the service never answered ping"; exit 2; fi

checks=0
failures=0
pass() { checks=$((checks + 1)); echo "ok   $1"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); echo "FAIL $1"; }
replies() {
  local what="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then pass "$what"; else fail "$what: want '$want', got '$got'"; fi
}
contains() {
  local what="$1" got="$2" want="$3"
  if [[ "$got" == *"$want"* ]]; then pass "$what"; else fail "$what: want '$want' in '$got'"; fi
}
# Polls the db until the SQL prints `want`, or 10 s pass.
expect() {
  local what="$1" sql="$2" want="$3" got=""
  for _ in $(seq 50); do
    got="$(sqlite3 -cmd ".timeout 5000" "$db" "$sql" 2>&1)" && [[ "$got" == "$want" ]] && { pass "$what"; return; }
    sleep 0.2
  done
  fail "$what: want '$want', got '$got'"
}
state_has() {
  local what="$1" want="$2" got=""
  for _ in $(seq 50); do
    got="$(ipc state)"
    [[ "$got" == *"$want"* ]] && { pass "$what"; return; }
    sleep 0.2
  done
  fail "$what: want '$want' in '$got'"
}
sound_lines() { grep -c "^$1" "$cfg_dir/sound.log" || true; }
sound_is() {
  local what="$1" starts="$2" ends="$3" got=""
  for _ in $(seq 50); do
    got="$(sound_lines start)/$(sound_lines end)"
    [[ "$got" == "$starts/$ends" ]] && { pass "$what"; return; }
    sleep 0.2
  done
  fail "$what: want $starts starts and $ends ends, got $got"
}
alarm_reads() { grep -c "FROM alarms ORDER BY" "$cfg_dir/sqlite3.log" || true; }
state_editor() {
  local what="$1" want="$2" n="${3:-1}" got=""
  for _ in $(seq 50); do
    got="$(ipc tabState "$n")"
    [[ "$got" == "$want" ]] && { pass "$what"; return; }
    sleep 0.2
  done
  fail "$what: want '$want', got '$got'"
}

replies "the service is not loaded while its first read is held" "$(ipc state | grep -o '"loaded":[a-z]*')" '"loaded":false'
replies "the panel of widget 1 opens on the Alarms tab" "$(ipc openAlarms)" "ok"
ipc startNew > /dev/null
ipc setEditor "06:45" "Early" "" "9" "5" > /dev/null
ipc closePanel 1
replies "closing the panel before the service loads keeps the draft and says why" \
  "$(ipc tabState 1)" "-1|draft:true|06:45|-|toast:Error: not ready"
rm "$cfg_dir/hold-reads"
state_has "the service loads the seeded alarms" '"loaded":true,"alarms":4'
ipc discard > /dev/null
ipc clearToast
# Before the first tick nowMs is 0, so the next alarm sits on another day.
replies "nothing rings and no card is up before the first tick" \
  "$(ipc state)" '{"loaded":true,"alarms":4,"ringing":[],"cards":0,"soundBroken":false,"title":"","bar":"'"$today_name"' 06:00","snooze":false,"on":3}'
replies "a tick before any alarm is due rings nothing and names the next alarm" \
  "$(ipc tick "$(ms "$day 05:00")")" '{"loaded":true,"alarms":4,"ringing":[],"cards":0,"soundBroken":false,"title":"","bar":"06:00","snooze":false,"on":3}'
replies "every chip shows the note glyph and the next alarm" "$(ipc chips)" "{note}  {alarm} 06:00|{note}  {alarm} 06:00|{note}  {alarm} 06:00"
contains "a left click on an idle chip opens that widget's panel" "$(ipc pressChip 1 left)" " open=true"
ipc closePanel 1
items_before=""
for _ in $(seq 50); do
  items_before="$(ipc itemsState)"
  [[ "$items_before" == "6|4|toast:" ]] && break
  sleep 0.2
done
replies "the Items tab of widget 1 lists the seeded rows" "$items_before" "6|4|toast:"
ringing_wake='"ringing":[1],"cards":3,"soundBroken":false,"title":"Wake up","bar":"'"$tomorrow_name"' 07:30","snooze":false,"on":1}'

# A read that starts before the tick's writes and lands after them must not
# bring the tick's own patches back.
touch "$cfg_dir/hold-writes" "$cfg_dir/hold-reads"
reads_before="$(alarm_reads)"
sqlite3 -cmd ".timeout 5000" "$db" "INSERT INTO history (type, title, action, ts) VALUES ('note', 'outside', 'added', 1)"
for _ in $(seq 50); do (( $(alarm_reads) > reads_before )) && break; sleep 0.1; done
replies "an outside write starts an alarms read, held" "$(( $(alarm_reads) > reads_before ))" "1"

t0730="$(ms "$day 07:30")"
replies "at 07:30 the daily alarm rings on every screen and the two one-shots from 06:00 are missed" \
  "$(ipc tick "$t0730")" '{"loaded":true,"alarms":4,'"$ringing_wake"
sound_is "one player runs for three screens" 1 0
replies "every chip reads the bell and the title, painted active" "$(ipc chips)" "{bell} Wake up*|{bell} Wake up*|{bell} Wake up*"
replies "the chip's tooltip names the ring, for a vertical bar that shows the bell alone" "$(ipc tooltip 2)" "Omanotes: Wake up is ringing · click to stop"
replies "one notification lists both missed alarms" "$(wc -l < "$cfg_dir/notify.log")" "1"
contains "the notification is headed by the count" "$(cat "$cfg_dir/notify.log")" "2 missed alarms"
contains "and names the first missed alarm with how late it is" "$(cat "$cfg_dir/notify.log")" "06:00 · Pills, 1 h 30 min late"
contains "and the second" "$(cat "$cfg_dir/notify.log")" "06:10 · Standup, 1 h 20 min late"
contains "the card shows the clock, the title and the detail" "$(ipc cardText 2)" "07:30|Wake up|Alarm · every day"
contains "the card's buttons name the snooze length" "$(ipc cardText 2)" "Snooze 9 min"

rm "$cfg_dir/hold-reads"
sleep 0.5
replies "the stale read lands and the next tick still rings nothing new" \
  "$(ipc tick "$(( t0730 + 1000 ))")" '{"loaded":true,"alarms":4,'"$ringing_wake"
rm "$cfg_dir/hold-writes"
expect "the ring is written to the daily alarm" "SELECT last_fired_at_ms FROM alarms WHERE id = 1" "$t0730"
expect "the missed one-shots are consumed and switched off" "SELECT group_concat(enabled || ':' || last_fired_at_ms) FROM alarms WHERE id IN (2, 3)" \
  "0:$(ms "$day 06:00"),0:$(ms "$day 06:10")"
replies "the tick wrote one row per due alarm" "$(grep -c "UPDATE alarms SET" "$cfg_dir/sqlite3.log" || true)" "3"
replies "a tick after the writes landed rings nothing new either" \
  "$(ipc tick "$(( t0730 + 2000 ))")" '{"loaded":true,"alarms":4,'"$ringing_wake"
sound_is "and starts no second player" 1 0
replies "and sends no second notification" "$(wc -l < "$cfg_dir/notify.log")" "1"

contains "Snooze on the card of screen 2 quiets the ring and names the snooze as the next alarm" \
  "$(ipc click 2 "Snooze")" '"ringing":[],"cards":3,"soundBroken":false,"title":"","bar":"07:39","snooze":true,"on":1}'
state_has "and the cards go down on every screen" '"ringing":[],"cards":0'
replies "the chips show the snooze glyph and the snooze time" "$(ipc chips)" "{note}  {snooze} 07:39|{note}  {snooze} 07:39|{note}  {snooze} 07:39"
sound_is "and stops the player" 1 1
snoozed="$(( t0730 + 2000 + 9 * 60000 ))"
expect "the snooze is written from the last tick" "SELECT snoozed_until_ms || ':' || auto_snoozes FROM alarms WHERE id = 1" "$snoozed:0"
replies "the snooze rings when its time comes" \
  "$(ipc tick "$snoozed")" '{"loaded":true,"alarms":4,'"$ringing_wake"
sound_is "with a new player" 2 1
contains "Stop on the card quiets the ring" "$(ipc click 1 "Stop")" '"ringing":[],"cards":3,"soundBroken":false,"title":"","bar":"'"$tomorrow_name"' 07:30","snooze":false,"on":1}'
state_has "and takes the cards down" '"ringing":[],"cards":0'
sound_is "and stops the player" 2 2
expect "and the snooze is consumed" "SELECT snoozed_until_ms FROM alarms WHERE id = 1" "0"

# An alarm nobody answers snoozes itself three times, then stays quiet.
sqlite3 -cmd ".timeout 5000" "$db" "INSERT INTO alarms (id, hour, minute, label, days, enabled, snooze_minutes, ring_minutes, armed_at_ms) VALUES (5, 8, 30, 'Unanswered', 0, 1, 1, 1, $yesterday)"
state_has "the service picks up an alarm inserted outside" '"alarms":5'
t0830="$(ms "$day 08:30")"
periods=""
for minute in 0 1 2 3 4 5 6 7; do
  got="$(ipc tick "$(( t0830 + minute * 60000 ))")"
  [[ "$got" == *'"ringing":[5]'* ]] && periods="${periods}R" || periods="${periods}."
done
replies "one minute of ringing, one of snooze, four times" "$periods" "R.R.R.R."
sound_is "each period starts and ends a player" 6 6
expect "the fourth expiry earns no snooze and leaves the count at three" \
  "SELECT snoozed_until_ms || ':' || auto_snoozes || ':' || enabled FROM alarms WHERE id = 5" "0:3:0"

# A player that fails at once is not restarted forever, and the card stays up.
touch "$cfg_dir/sound-fails"
sqlite3 -cmd ".timeout 5000" "$db" "INSERT INTO alarms (id, hour, minute, label, days, enabled, armed_at_ms) VALUES (6, 9, 0, 'Silent', 0, 1, $yesterday)"
state_has "the service picks up the sixth alarm" '"alarms":6'
contains "the alarm rings with a broken player" "$(ipc tick "$(ms "$day 09:00")")" '"ringing":[6],"cards":3'
sleep 3
state_has "three quick failures latch the sound off" '"ringing":[6],"cards":3,"soundBroken":true'
replies "the player was tried at most three times" "$(( $(sound_lines fail) <= 3 && $(sound_lines fail) >= 1 ))" "1"
replies "a right click on a ringing chip stops the ring and opens no panel" "$(ipc pressChip 3 right)" \
  "{note}  {alarm} $tomorrow_name 07:30|{note}  {alarm} $tomorrow_name 07:30|{note}  {alarm} $tomorrow_name 07:30 open=false"
state_has "and the cards go down" '"ringing":[],"cards":0'
rm "$cfg_dir/sound-fails"

# A repeating alarm switched off outside, with sqlite3, leaves the card.
sqlite3 -cmd ".timeout 5000" "$db" "INSERT INTO alarms (id, hour, minute, label, days, enabled, armed_at_ms) VALUES (7, 9, 30, 'Outside', 127, 1, $yesterday)"
state_has "the service picks up the seventh alarm" '"alarms":7'
contains "the repeating alarm rings" "$(ipc tick "$(ms "$day 09:30")")" '"ringing":[7],"cards":3'
sqlite3 -cmd ".timeout 5000" "$db" "UPDATE alarms SET enabled = 0 WHERE id = 7"
state_has "switching it off outside takes the card down" '"ringing":[],"cards":0'
sound_is "and stops the player" 7 7

sleep 1
replies "the ticks left the Items rows, the History count and the Items toast alone" \
  "$(ipc itemsState)" "$(sqlite3 -cmd ".timeout 5000" "$db" "SELECT COUNT(*) FROM items")|$(sqlite3 -cmd ".timeout 5000" "$db" "SELECT COUNT(*) FROM history")|toast:"

disk_error="toast:Error: disk I/O error"
sql() { sqlite3 -cmd ".timeout 5000" "$db" "$1"; }
tab_is() {
  local what="$1" n="$2" fields="$3" want="$4" got=""
  for _ in $(seq 50); do
    got="$(ipc tabState "$n" | cut -d'|' -f"$fields")"
    [[ "$got" == "$want" ]] && { pass "$what"; return; }
    sleep 0.2
  done
  fail "$what: want '$want', got '$got'"
}
updates() { grep -c "UPDATE alarms SET" "$cfg_dir/sqlite3.log" || true; }

replies "the panel of widget 1 opens on the Alarms tab" "$(ipc openAlarms)" "ok"
contains "+ Alarm opens a draft" "$(ipc startNew)" "|draft:true||-|toast:"
ipc closePanel 1
replies "closing the panel drops a draft nobody touched, without a warning" "$(ipc tabState 1 | cut -d'|' -f2,5)" "draft:false|toast:"
replies "the panel of widget 1 opens on the Alarms tab again" "$(ipc openAlarms)" "ok"
contains "+ Alarm opens a draft again" "$(ipc startNew)" "|draft:true||-|toast:"
ipc setEditor "06:45" "Gym" "1,2,3,4,5" "10" "2" > /dev/null
for n in 1 2 3; do ipc clearToastOf "$n"; done
ipc closePanel 1
expect "closing the panel commits the draft with every field" \
  "SELECT hour || '|' || minute || '|' || label || '|' || days || '|' || enabled || '|' || snooze_minutes || '|' || ring_minutes FROM alarms WHERE label = 'Gym'" \
  "6|45|Gym|62|1|10|2"
gym="$(sql "SELECT id FROM alarms WHERE label = 'Gym'")"
state_editor "the new alarm is selected once the insert lands" "$gym|draft:false|06:45|Delete|toast:Added alarm"
for n in 2 3; do
  replies "widget $n keeps its selection and shows no toast for the add" "$(ipc tabState "$n" | cut -d'|' -f1,2,5)" "2|draft:false|toast:"
done
replies "the panel of widget 1 opens on the Alarms tab with the new alarm" "$(ipc openAlarms)" "ok"
ipc toggleRow "$gym" > /dev/null
expect "the row switch turns the alarm off" "SELECT enabled || ':' || snoozed_until_ms FROM alarms WHERE id = $gym" "0:0"
ipc toggleRow "$gym" > /dev/null
expect "and back on, armed at the last tick" "SELECT enabled || ':' || armed_at_ms FROM alarms WHERE id = $gym" "1:$(ms "$day 09:30")"
touch "$cfg_dir/fail-writes"
on_before="$(ipc state | grep -o '"on":[0-9]*')"
for n in 1 2 3; do ipc clearToastOf "$n"; done
ipc toggleRow "$gym" > /dev/null
replies "a switch whose write fails still shows off at once" "$(ipc state | grep -o '"on":[0-9]*')" "\"on\":$(( ${on_before#*:} - 1 ))"
tab_is "the widget that flipped it shows the failure" 1 5 "$disk_error"
ipc clearToast
sleep 1.2
replies "while the row on disk is still on" "$(sql "SELECT enabled FROM alarms WHERE id = $gym")" "1"
replies "the retries of that write show no toast" "$(ipc tabState 1 | cut -d'|' -f5)" "toast:"
for n in 2 3; do
  replies "widget $n shows nothing of the failed switch" "$(ipc tabState "$n" | cut -d'|' -f5)" "toast:"
done
rm "$cfg_dir/fail-writes"
expect "and the retry lands once the write can" "SELECT enabled FROM alarms WHERE id = $gym" "0"
ipc toggleRow "$gym" > /dev/null
expect "the next switch lands at once" "SELECT enabled FROM alarms WHERE id = $gym" "1"
sleep 0.3
updates_before="$(updates)"
contains "a repeat chip on a saved alarm leaves it unsaved" "$(ipc toggleDay 6)" "|dirty:true"
sleep 0.5
replies "and writes nothing until the editor is left" "$(updates)" "$updates_before"
ipc setEditor "06:50" "Gym" "1,2,3,4,5" "10" "2" > /dev/null
replies "switching to the Items tab saves the edit" "$(ipc setTab 1 items | cut -d'|' -f1-3)" "$gym|draft:false|06:50"
expect "a changed time re-arms the alarm and switches it on" "SELECT hour || ':' || minute || ':' || enabled FROM alarms WHERE id = $gym" "6:50:1"
ipc setTab 1 alarms > /dev/null
ipc clearToast
ipc setEditor "06:50" "Gym at the club" "1,2,3,4,5" "10" "2" > /dev/null
contains "editing the label saves it with a toast" "$(ipc leave)" "|toast:Saved — Gym at the club"
expect "a label change keeps the alarm as it was" "SELECT label || ':' || enabled FROM alarms WHERE id = $gym" "Gym at the club:1"
ipc setEditor "" "Gym at the club" "1,2,3,4,5" "10" "2" > /dev/null
contains "an emptied time keeps the saved one" "$(ipc leave)" "|06:50|Delete|toast:Time can't be read — kept 06:50"
contains "the first Delete arms" "$(ipc pressDelete)" "|Confirm|toast:Delete again to confirm"
ipc pressDelete > /dev/null
expect "the second Delete removes the alarm" "SELECT COUNT(*) FROM alarms WHERE id = $gym" "0"
sql "INSERT INTO alarms (id, hour, minute, label, days, enabled, armed_at_ms) VALUES (9, 7, 45, '', 0, 0, $yesterday)"
state_has "the service picks up an unlabeled alarm" '"alarms":8'
ipc pickAlarm 9 > /dev/null
ipc pressDelete > /dev/null
replies "deleting an unlabeled alarm in the middle names its time and selects the next row" \
  "$(ipc pressDelete)" "5|draft:false|08:30|Delete|toast:Deleted — 07:45"
expect "and removes it" "SELECT COUNT(*) FROM alarms WHERE id = 9" "0"
ipc clearToast
ipc pickAlarm 3 > /dev/null
ipc setEditor "06:10" "Standup moved" "" "9" "5" > /dev/null
sql "DELETE FROM alarms WHERE id = 3"
tab_is "an alarm removed elsewhere while its edit is unsaved says so" 1 5 "toast:Alarm removed elsewhere"
ipc leave > /dev/null
sleep 0.5
replies "and its unsaved edit is not written anywhere" "$(sql "SELECT COUNT(*) FROM alarms WHERE id = 3 OR label = 'Standup moved'")" "0"
ipc clearToast
ipc startNew > /dev/null
ipc setEditor "25:00" "Late" "" "9" "5" > /dev/null
contains "a draft without a readable time stays open with the warning" "$(ipc leave)" "|draft:true|25:00|-|toast:New alarm needs a time like 07:30"
ipc discard > /dev/null
for n in 1 2 3; do ipc clearToastOf "$n"; done
touch "$cfg_dir/fail-insert"
ipc startNew > /dev/null
ipc setEditor "06:55" "Failing" "" "9" "5" > /dev/null
ipc leave > /dev/null
state_editor "a failed insert shows the error and gives the draft back" "$(ipc editorState | cut -d'|' -f1)|draft:true|06:55|-|$disk_error"
for n in 2 3; do
  replies "widget $n gets neither the draft nor the error of that insert" "$(ipc tabState "$n" | cut -d'|' -f2,5)" "draft:false|toast:"
done
failing_inserts() { grep -c "INSERT INTO alarms.*'Failing'" "$cfg_dir/sqlite3.log" || true; }
ipc closePanel 1
# The time field of widget 1 keeps focus in its hidden window until another
# window opens, and that blur commits too, so widget 3 takes it first.
replies "the panel of widget 3 opens" "$(ipc openPanel 3)" "open=true"
ipc closePanel 3
sleep 1
tab_is "widget 1 still holds its draft while inserts fail" 1 2,3 "draft:true|06:55"
attempts="$(failing_inserts)"
replies "the panel of widget 2 opens" "$(ipc openPanel 2)" "open=true"
ipc closePanel 2
sleep 1
replies "closing the panel of widget 2 sends no insert of widget 1's draft" "$(failing_inserts)" "$attempts"
rm "$cfg_dir/fail-insert"
ipc clearToast
replies "the panel of widget 1 opens on the Alarms tab again" "$(ipc openAlarms)" "ok"
ipc closePanel 1
expect "widget 1 saves its draft once the insert can land" "SELECT COUNT(*) FROM alarms WHERE label = 'Failing'" "1"
replies "the alarm edits wrote no history row" "$(sql "SELECT COUNT(*) FROM history")" "5"

sql "INSERT INTO alarms (id, hour, minute, label, days, enabled, snoozed_until_ms, last_fired_at_ms, armed_at_ms)
  VALUES (30, 10.4, 0, 'Malformed', 0, 1, -1, 0.5, $yesterday.5)"
state_has "the service picks up the malformed alarm" '"alarms":8'
notices_before="$(wc -l < "$cfg_dir/notify.log")"
t1030="$(ms "$day 10:30")"
for second in 0 1 2; do ipc tick "$(( t1030 + second * 1000 ))" > /dev/null; done
replies "the malformed alarm is missed with one notification over three ticks" \
  "$(( $(wc -l < "$cfg_dir/notify.log") - notices_before ))" "1"
expect "and is consumed and switched off, written back whole" \
  "SELECT hour || ':' || enabled || ':' || last_fired_at_ms || ':' || snoozed_until_ms FROM alarms WHERE id = 30" \
  "10:0:$(ms "$day 10:00"):0"

filler=$(( 49 - $(sql "SELECT COUNT(*) FROM alarms") ))
sql "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < $filler)
  INSERT INTO alarms (hour, minute, label, days, enabled, armed_at_ms) SELECT 23, 0, 'Filler', 0, 0, $yesterday FROM n"
state_has "the service picks up 49 alarms" '"alarms":49'
replies "the panel of widget 1 opens on the Alarms tab for the limit" "$(ipc openAlarms)" "ok"
touch "$cfg_dir/hold-inserts"
ipc startNew > /dev/null
ipc setEditor "05:00" "Fiftieth" "" "9" "5" > /dev/null
contains "the fiftieth alarm is sent" "$(ipc leave)" "|draft:false|"
ipc startNew > /dev/null
ipc setEditor "05:01" "Fifty-first" "" "9" "5" > /dev/null
replies "a draft past the limit, with the fiftieth still in flight, stays open and says why" \
  "$(ipc leave | cut -d'|' -f2,3,5)" "draft:true|05:01|toast:Error: 50 alarms is the limit"
rm "$cfg_dir/hold-inserts"
state_has "the fiftieth lands" '"alarms":50'
ipc clearToast
replies "at the limit a draft left again still stays open" \
  "$(ipc leave | cut -d'|' -f2,3,5)" "draft:true|05:01|toast:Error: 50 alarms is the limit"
ipc discard > /dev/null
ipc closePanel 1
replies "the database holds exactly 50 alarms" "$(sql "SELECT COUNT(*) FROM alarms")" "50"

replies "the panel of widget 1 opens on the Alarms tab for the scroll" "$(ipc openAlarms)" "ok"
ipc pickAlarm "$(sql "SELECT MAX(id) FROM alarms")" > /dev/null
replies "the list of 50 alarms scrolls" "$(ipc scrollAlarms 1 300)" "300"
reads_before="$(alarm_reads)"
sql "UPDATE alarms SET label = 'Moved' WHERE id = (SELECT MAX(id) FROM alarms)"
for _ in $(seq 50); do (( $(alarm_reads) > reads_before )) && break; sleep 0.1; done
sleep 0.5
replies "a reload after an outside write keeps the list where it was scrolled" "$(ipc alarmsScroll 1)" "300"
ipc toggleRow "$(sql "SELECT MAX(id) FROM alarms")" > /dev/null
replies "and so does a switch flipped in the list" "$(ipc alarmsScroll 1)" "300"
ipc closePanel 1

ipc quit > /dev/null || true
wait "$qs_pid" || true
logged_failures="$(grep -o "omanotes db: .*" "$cfg_dir/qs.log" | sed 's/^omanotes db: //' | sort -u | tr '\n' ';' || true)"
replies "only the injected failures are logged" "$logged_failures" "disk I/O error;"
replies "the failed save was retried at least once before it landed" \
  "$(( $(grep -c "omanotes db: disk I/O error" "$cfg_dir/qs.log" || true) >= 3 ))" "1"
replies "the broken player is logged once" "$(grep -c "omanotes: cannot play" "$cfg_dir/qs.log" || true)" "1"

(( failures == 0 )) || tail -n 40 "$cfg_dir/qs.log"
echo "alarm: $checks checks, $failures failed"
exit $(( failures > 0 ))
