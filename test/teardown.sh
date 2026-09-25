#!/usr/bin/env bash
# Runs panel.sh against a copy whose bar widget never answers ping, so it exits
# early, then asserts it left no Quickshell running behind it.

set -euo pipefail

src="$(cd "$(dirname "$0")/.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

copy="$sandbox/omanotes"
mkdir "$copy"
cp -r "$src/Panel.qml" "$src/data" "$src/ui" "$src/test" "$copy/"
sed 's/function ping(): string { return "ok" }/function ping(): string { return "down" }/' \
  "$src/BarWidget.qml" > "$copy/BarWidget.qml"

status=0
TMPDIR="$sandbox" "$copy/test/panel.sh" > "$sandbox/panel.log" 2>&1 || status=$?

checks=0
failures=0
pass() { checks=$((checks + 1)); echo "ok   $1"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); echo "FAIL $1"; }

if (( status == 2 )) && grep -q "never answered ping" "$sandbox/panel.log"; then
  pass "panel.sh stops when the widget never answers"
else
  fail "panel.sh stops when the widget never answers: exit $status"
  tail -n 20 "$sandbox/panel.log"
fi

left="$(pgrep -f "qs -p $sandbox/" || true)"
if [[ -z "$left" ]]; then
  pass "no Quickshell outlives panel.sh"
else
  fail "no Quickshell outlives panel.sh: $(ps -o pid=,args= -p "${left//$'\n'/,}" | tr '\n' ';')"
  kill $left 2> /dev/null || true
fi

echo "teardown: $checks checks, $failures failed"
exit $(( failures > 0 ))
