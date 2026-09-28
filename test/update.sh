#!/usr/bin/env bash
# Drives data/update.sh against a throwaway origin and clone, with stubs for
# the validator, the shell and the notification, and a throwaway
# XDG_STATE_HOME. Asserts the state file each mode leaves, that apply refuses
# everything that could lose work before touching the tree, the rollback on a
# failed validation, the lock, and an update that rewrites the script itself.
# Needs git and flock, not qs.

set -euo pipefail
worktree="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com \
  GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com XDG_STATE_HOME="$tmp/state"
mkdir "$tmp/bin"
for stub in omarchy-shell omarchy-notification-send; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/%s.log"\n' "$tmp" "$stub" > "$tmp/bin/$stub"
done
printf '#!/usr/bin/env bash\n[[ -e "%s/validate-fails" ]] && { echo "manifest.json: bad entry point" >&2; exit 1; }\nexit 0\n' "$tmp" \
  > "$tmp/bin/omarchy-plugin-validate"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
state="$tmp/state/omanotes/update"

checks=0
failures=0
pass() { checks=$((checks + 1)); echo "ok   $1"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); echo "FAIL $1"; }
replies() {
  local what="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then pass "$what"; else fail "$what: want '$want', got '$got'"; fi
}

# Every `key value` line of the state file but `at`, joined with |.
record() { grep -v '^at ' "$state" | tr '\n' '|'; }
field() { sed -n "s/^$1 //p" "$state" | head -n 1; }
run() { bash "$1/data/update.sh" "$2" "$1"; }
head_of() { git -C "$1" rev-parse --short HEAD; }

git init --quiet --bare -b main "$tmp/origin.git"
git clone --quiet "$tmp/origin.git" "$tmp/dev" 2> /dev/null
mkdir "$tmp/dev/data"
cp "$worktree/data/update.sh" "$tmp/dev/data/update.sh"
printf '{\n  "id": "othavi0.omanotes",\n  "version": "1.0.0"\n}\n' > "$tmp/dev/manifest.json"
echo "first" > "$tmp/dev/notes.txt"
git -C "$tmp/dev" add -A
git -C "$tmp/dev" commit --quiet -m "feat: first"
git -C "$tmp/dev" push --quiet origin main
git clone --quiet "$tmp/origin.git" "$tmp/plugin"
plugin="$tmp/plugin"
first="$(head_of "$plugin")"
publish() {
  echo "$2" >> "$tmp/dev/notes.txt"
  git -C "$tmp/dev" commit --quiet -am "$1"
  git -C "$tmp/dev" push --quiet origin main
}

replies "status on a clean clone names the version, the branch, the head and no local changes" \
  "$(run "$plugin" status | tr '\n' '|')" "git 1|version 1.0.0|branch main|head $first|dirty 0|"
replies "a check with nothing new records it up to date" "$(run "$plugin" check; record)" \
  "phase checked|head $first|branch main|behind 0|error |detail |step |from |to |"

publish "fix: busca ignora acento no corpo" "second"
publish $'feat: "aspas" e\ttab no assunto' "third"
second="$(git -C "$tmp/dev" rev-parse --short HEAD~1)"
third="$(git -C "$tmp/dev" rev-parse --short HEAD)"
run "$plugin" check
replies "a check counts two new commits on origin/main" "$(field behind)|$(field error)" "2|"
replies "and lists them newest first, subjects kept whole" "$(grep '^commit ' "$state" | tr '\n' '|')" \
  "commit $third feat: \"aspas\" e"$'\t'"tab no assunto|commit $second fix: busca ignora acento no corpo|"
replies "a check fetches only into .git, so the plugin folder is untouched" "$(head_of "$plugin")|$(cat "$plugin/notes.txt")" "$first|first"

echo "local edit" >> "$plugin/notes.txt"
run "$plugin" check
replies "a check on a folder with local changes says so" "$(field behind)|$(field error)" "2|dirty"
replies "status shows the local changes" "$(run "$plugin" status | grep '^dirty')" "dirty 1"
run "$plugin" apply || true
replies "apply refuses a folder with local changes and records why" "$(field phase)|$(field error)" "failed|dirty"
replies "and touches neither the head nor the changed file" "$(head_of "$plugin")|$(tail -n 1 "$plugin/notes.txt")" "$first|local edit"
replies "nothing reloaded and nothing was announced" "$(cat "$tmp/omarchy-shell.log" 2> /dev/null | wc -l)|$(cat "$tmp/omarchy-notification-send.log" 2> /dev/null | wc -l)" "0|0"
git -C "$plugin" checkout --quiet -- notes.txt

run "$plugin" apply
replies "apply on a clean folder fast-forwards to origin/main" "$(head_of "$plugin")" "$third"
replies "and records the update from the old head to the new one" \
  "$(field phase)|$(field from)|$(field to)|$(field head)|$(field behind)|$(field error)|$(field step)" "updated|$first|$third|$third|2||"
replies "the shell is asked to reload once" "$(cat "$tmp/omarchy-shell.log")" "shell rescanPlugins"
replies "and one notification names the change" "$(cat "$tmp/omarchy-notification-send.log")" "Omanotes updated $first → $third · 2 commits"
replies "a check right after finds nothing new" "$(run "$plugin" check; field behind)|$(field error)" "0|"

publish "feat: entrada quebrada" "fourth"
touch "$tmp/validate-fails"
run "$plugin" apply || true
rm "$tmp/validate-fails"
replies "an update that does not validate is rolled back to the old head" "$(head_of "$plugin")|$(tail -n 1 "$plugin/notes.txt")" "$third|third"
replies "and recorded as invalid, with the validator's reason" "$(field phase)|$(field error)|$(field detail)" "failed|invalid|manifest.json: bad entry point"

git -C "$plugin" remote set-url origin "$tmp/gone.git"
run "$plugin" check
replies "an origin that cannot be reached reads as offline" "$(field error)" "offline"
replies "with git's reason" "$(field detail | grep -c "gone.git" || true)" "1"
git -C "$plugin" remote remove origin
run "$plugin" check
replies "a clone without origin says so" "$(field error)" "noOrigin"
git -C "$plugin" remote add origin "$tmp/origin.git"

git -C "$plugin" checkout --quiet -b feat/x
run "$plugin" check
replies "a check on another branch still counts what main has" "$(field branch)|$(field behind)|$(field error)" "feat/x|1|offMain"
run "$plugin" apply || true
replies "apply on another branch refuses and leaves the head" "$(field phase)|$(field error)|$(head_of "$plugin")" "failed|offMain|$third"
git -C "$plugin" checkout --quiet main

echo "mine" > "$plugin/local.txt"
git -C "$plugin" add local.txt
git -C "$plugin" commit --quiet -m "local only"
local_head="$(head_of "$plugin")"
run "$plugin" apply || true
replies "apply on a main with a commit origin lacks refuses as diverged" "$(field phase)|$(field error)|$(head_of "$plugin")" "failed|diverged|$local_head"
git -C "$plugin" reset --quiet --hard "$third"

mkdir "$tmp/plain"
cp "$worktree/data/update.sh" "$tmp/plain/" && mkdir "$tmp/plain/data" && mv "$tmp/plain/update.sh" "$tmp/plain/data/"
printf '{ "version": "1.0.0" }\n' > "$tmp/plain/manifest.json"
replies "status on a folder that is no checkout says so" "$(run "$tmp/plain" status | tr '\n' '|')" "git 0|version 1.0.0|"
run "$tmp/plain" check
replies "and a check records notGit" "$(field error)" "notGit"

git init --quiet -b main "$tmp/parent"
mkdir -p "$tmp/parent/plugins/omanotes"
cp -r "$tmp/plain/." "$tmp/parent/plugins/omanotes/"
git -C "$tmp/parent" add -A
git -C "$tmp/parent" commit --quiet -m "parent"
parent_head="$(head_of "$tmp/parent")"
run "$tmp/parent/plugins/omanotes" apply || true
replies "a copy inside another repository counts as no checkout" "$(field phase)|$(field error)" "failed|notGit"
replies "and the parent repository is untouched" "$(head_of "$tmp/parent")|$(git -C "$tmp/parent" status --porcelain | wc -l)" "$parent_head|0"

publish "feat: quinto" "fifth"
( run "$plugin" check ) & first_check=$!
( run "$plugin" check ) & second_check=$!
wait "$first_check" && wait "$second_check" && pass "two checks at once both finish" || fail "two checks at once both finish"
replies "and agree" "$(field behind)" "2"
before="$(cat "$state")"
exec 8> "$tmp/state/omanotes/update.lock"
flock 8
code=0
run "$plugin" apply 2> /dev/null || code=$?
exec 8>&-
replies "an apply while another holds the lock exits as locked" "$code" "3"
replies "and writes nothing" "$(cat "$state")" "$before"
replies "nor pulls" "$(head_of "$plugin")" "$third"

sed -i '2i # The whole script is read first, so this line moves every line below it.' "$tmp/dev/data/update.sh"
git -C "$tmp/dev" commit --quiet -am "chore: o script de update muda a si mesmo"
git -C "$tmp/dev" push --quiet origin main
newest="$(head_of "$tmp/dev")"
: > "$tmp/omarchy-shell.log"
run "$plugin" apply
replies "an update that rewrites the update script itself still ends updated" "$(field phase)|$(field to)|$(head_of "$plugin")" "updated|$newest|$newest"
replies "with the new script in place" "$(grep -c "The whole script is read first" "$plugin/data/update.sh")" "1"
replies "after one reload" "$(wc -l < "$tmp/omarchy-shell.log")" "1"

echo "update: $checks checks, $failures failed"
exit $(( failures > 0 ))
