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

day="$(date +%F)"
ms() { echo $(( $(date -d "$1" +%s) * 1000 )); }
yesterday="$(ms "$day 12:00 1 day ago")"
today_name="$(date +%a)"
tomorrow_name="$(date -d "$day 1 day" +%a)"
sound_file="$cfg_dir/alarm.oga"
: > "$sound_file"

real_sqlite3="$(command -v sqlite3)"
mkdir "$cfg_dir/bin"
# Every call is logged. UPDATEs of alarms wait while hold-writes exists, a
# read of alarms runs at once but prints only once hold-reads is gone, and an
# INSERT fails while fail-insert exists.
cat > "$cfg_dir/bin/sqlite3" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$cfg_dir/sqlite3.log"
if [[ "\$*" == *"UPDATE alarms"* ]]; then
  for _ in \$(seq 400); do [[ -e "$cfg_dir/hold-writes" ]] || break; sleep 0.05; done
fi
if [[ "\$*" == *"INSERT INTO alarms"* && -e "$cfg_dir/fail-insert" ]]; then echo "Error: disk I/O error" >&2; exit 10; fi
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

sqlite3 "$db" "INSERT INTO alarms (id, hour, minute, label, days, enabled, armed_at_ms) VALUES
  (1, 7, 30, 'Wake up', 127, 1, $yesterday),
  (2, 6, 0, 'Pills', 0, 1, $yesterday),
  (3, 6, 10, 'Standup', 0, 1, $yesterday),
  (4, 7, 30, 'Off', 0, 0, $yesterday);"

cat > "$cfg_dir/shell.qml" <<'QML'
import QtQuick
import Quickshell
import Quickshell.Io
import "ui" as Ui

ShellRoot {
  id: sr
  property var cards: []

  // The ring window a test can create offscreen: a plain window holding the
  // shipped card.
  Component {
    id: stubRing
    FloatingWindow {
      id: win
      required property var modelData
      implicitWidth: 400
      implicitHeight: 220
      Ui.RingCard { service: svc.item }
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

  IpcHandler {
    target: "omanotes-test"
    function ping(): string { return svc.item ? "ok" : "loading" }
    function tick(ms: string): string { svc.item.tick(Number(ms)); return sr.state() }
    function state(): string { return sr.state() }
    // Clicks the button whose text starts with `label` on the card of screen `n`.
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
    got="$(sqlite3 "$db" "$sql" 2>&1)" && [[ "$got" == "$want" ]] && { pass "$what"; return; }
    sleep 0.2
  done
  fail "$what: want '$want', got '$got'"
}
# Polls state() until it contains `want`.
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

state_has "the service loads the seeded alarms" '"loaded":true,"alarms":4'
# Before the first tick nowMs is 0, so the next alarm sits on another day.
replies "nothing rings and no card is up before the first tick" \
  "$(ipc state)" '{"loaded":true,"alarms":4,"ringing":[],"cards":0,"soundBroken":false,"title":"","bar":"'"$today_name"' 06:00","snooze":false,"on":3}'
replies "a tick before any alarm is due rings nothing and names the next alarm" \
  "$(ipc tick "$(ms "$day 05:00")")" '{"loaded":true,"alarms":4,"ringing":[],"cards":0,"soundBroken":false,"title":"","bar":"06:00","snooze":false,"on":3}'
ringing_wake='"ringing":[1],"cards":3,"soundBroken":false,"title":"Wake up","bar":"'"$tomorrow_name"' 07:30","snooze":false,"on":1}'

# A read that starts before the tick's writes and lands after them must not
# bring the tick's own patches back.
touch "$cfg_dir/hold-writes" "$cfg_dir/hold-reads"
reads_before="$(alarm_reads)"
sqlite3 "$db" "INSERT INTO history (type, title, action, ts) VALUES ('note', 'outside', 'added', 1)"
for _ in $(seq 50); do (( $(alarm_reads) > reads_before )) && break; sleep 0.1; done
replies "an outside write starts an alarms read, held" "$(( $(alarm_reads) > reads_before ))" "1"

t0730="$(ms "$day 07:30")"
replies "at 07:30 the daily alarm rings on every screen and the two one-shots from 06:00 are missed" \
  "$(ipc tick "$t0730")" '{"loaded":true,"alarms":4,'"$ringing_wake"
sound_is "one player runs for three screens" 1 0
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
sqlite3 "$db" "INSERT INTO alarms (id, hour, minute, label, days, enabled, snooze_minutes, ring_minutes, armed_at_ms) VALUES (5, 8, 30, 'Unanswered', 0, 1, 1, 1, $yesterday)"
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
sqlite3 "$db" "INSERT INTO alarms (id, hour, minute, label, days, enabled, armed_at_ms) VALUES (6, 9, 0, 'Silent', 0, 1, $yesterday)"
state_has "the service picks up the sixth alarm" '"alarms":6'
contains "the alarm rings with a broken player" "$(ipc tick "$(ms "$day 09:00")")" '"ringing":[6],"cards":3'
sleep 3
state_has "three quick failures latch the sound off" '"ringing":[6],"cards":3,"soundBroken":true'
replies "the player was tried at most three times" "$(( $(sound_lines fail) <= 3 && $(sound_lines fail) >= 1 ))" "1"
ipc click 3 "Stop" > /dev/null
rm "$cfg_dir/sound-fails"

# A repeating alarm switched off outside, with sqlite3, leaves the card.
sqlite3 "$db" "INSERT INTO alarms (id, hour, minute, label, days, enabled, armed_at_ms) VALUES (7, 9, 30, 'Outside', 127, 1, $yesterday)"
state_has "the service picks up the seventh alarm" '"alarms":7'
contains "the repeating alarm rings" "$(ipc tick "$(ms "$day 09:30")")" '"ringing":[7],"cards":3'
sqlite3 "$db" "UPDATE alarms SET enabled = 0 WHERE id = 7"
state_has "switching it off outside takes the card down" '"ringing":[],"cards":0'
sound_is "and stops the player" 7 7

ipc quit > /dev/null || true
wait "$qs_pid" || true
replies "no db failure is logged" "$(grep -o "omanotes db: .*" "$cfg_dir/qs.log" | tr '\n' ';' || true)" ""
replies "the broken player is logged once" "$(grep -c "omanotes: cannot play" "$cfg_dir/qs.log" || true)" "1"

(( failures == 0 )) || tail -n 40 "$cfg_dir/qs.log"
echo "alarm: $checks checks, $failures failed"
exit $(( failures > 0 ))
