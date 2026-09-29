#!/bin/bash
# Template of the omanotes-db the QML tests run. harness.sh copies it to
# $cfg_dir/bin/omanotes-db.<machine>, the file the Store resolves next to the
# plugin's data/ folder (see stub_db there), replacing @REAL@ (the binary of the
# checkout) and @CFG@ (the test's folder). It takes the argv and the stdin the
# Store sends, and passes both to the real binary unless a file in @CFG@ says
# to hold or fail the request:
#
#   db.log            one line per request: "<n> <kinds> <request>"; kinds is "sync"
#                     or "write", then a "write:<op>" word per write it carried
#   hold-sync         requests with no writes wait until the file is removed
#   hold-reads        the same, but after running: the answer lands stale
#   fail-list         a held read that carried a search fails with "disk I/O error"
#   hold-writes       requests with alarm.save or alarm.delete wait until the file is removed
#   hold-inserts      requests with alarm.insert wait until the file is removed
#   hold-any-write    requests with any write wait until the file is removed
#   fail-writes       requests with alarm.save or alarm.delete fail with "disk I/O error"
#   refuse-writes     requests with alarm.save or alarm.delete fail as bad_request, as a
#                     record the binary refuses
#   fail-insert       requests with alarm.insert fail with "disk I/O error"
#   fail-sync         requests with no writes fail as a lock held outside
#   first-fails       the next request fails as a lock held outside, once
#   crash             the next request dies by SIGKILL with no answer, once
#   stall-journal     holds N: requests run with lib/stall-journal.c preloaded, so the Nth
#                     write of each stalls on the disk until the Lane kills the request
#
# A failure is what the binary does: exit 1 and {"err","detail"} on the last line
# of stderr. Builtins only until the real binary, but for sleep: a check races a
# request against a write made by hand right after it, and a slow stub would lose
# races the real binary wins. The Store starts it with an empty environment.
cfg='@CFG@'
real='@REAL@'
IFS= read -r -d '' req
lines=()
[[ -f "$cfg/db.log" ]] && mapfile -t lines < "$cfg/db.log"
n=$(( ${#lines[@]} + 1 ))
kinds=sync
[[ "$req" == *'"writes"'* ]] && kinds=write
rest="$req"
while [[ "$rest" =~ \"op\":\"([a-z.]+)\" ]]; do
  kinds="$kinds write:${BASH_REMATCH[1]}"
  rest="${rest#*"${BASH_REMATCH[0]}"}"
done
printf '%s %s %s\n' "$n" "$kinds" "$req" >> "$cfg/db.log"

wait_while() { while [[ -e "$cfg/$1" ]]; do sleep 0.05; done; }
disk() { printf '{"err":"io","detail":"disk I/O error"}\n' >&2; exit 1; }
busy() { printf '{"err":"busy","detail":"database is locked"}\n' >&2; exit 1; }
refuse() { printf '{"err":"bad_request","detail":"an alarm names every column"}\n' >&2; exit 1; }
saves=0; inserts=0
[[ "$kinds" == *write:alarm.save* || "$kinds" == *write:alarm.delete* ]] && saves=1
[[ "$kinds" == *write:alarm.insert* ]] && inserts=1
if [[ "$kinds" == sync ]]; then
  wait_while hold-sync
else
  wait_while hold-any-write
  (( inserts )) && wait_while hold-inserts
  (( saves )) && wait_while hold-writes
fi
if [[ -e "$cfg/crash" ]]; then rm -f "$cfg/crash"; kill -KILL $$; fi
if [[ -e "$cfg/first-fails" ]]; then rm -f "$cfg/first-fails"; busy; fi
if [[ "$kinds" == sync ]]; then
  [[ -e "$cfg/fail-sync" ]] && busy
  if [[ -e "$cfg/hold-reads" ]]; then
    failing=0
    [[ -e "$cfg/fail-list" && "$req" == *'"views":[{'* ]] && failing=1   # decided when the read starts
    # $(...) drops every last "\n", and a line without it is not whole
    # (ADR-0020): the x keeps the binary's bytes as they were.
    out="$("$real" "$@" <<< "$req"; c=$?; printf x; exit "$c")"
    code=$?
    out="${out%x}"
    wait_while hold-reads
    (( failing )) && disk
    printf '%s' "$out"
    exit "$code"
  fi
else
  (( inserts )) && [[ -e "$cfg/fail-insert" ]] && disk
  (( saves )) && [[ -e "$cfg/fail-writes" ]] && disk
  (( saves )) && [[ -e "$cfg/refuse-writes" ]] && refuse
fi
if [[ -e "$cfg/stall-journal" ]]; then
  read -r stall < "$cfg/stall-journal"
  LD_PRELOAD="$cfg/stall-journal.so" OMANOTES_STALL_JOURNAL="$stall" exec "$real" "$@" <<< "$req"
fi
exec "$real" "$@" <<< "$req"
