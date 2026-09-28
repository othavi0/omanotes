#!/usr/bin/env bash
# Drives data/update.sh against a throwaway origin and clone, with stubs for
# the validator, the shell and the notification, a git that reports how it
# was started, and a throwaway XDG_STATE_HOME. Asserts the state file each
# mode leaves, that apply refuses everything that could lose work and
# validates before it touches the folder, that `status` calls running at the
# same time never break a merge, the lock, and an update that rewrites the
# script itself. Needs git and flock, not qs.

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
# The validator also notes the request of the record apply left before it
# ran, and on demand fails, hangs until it is killed, or takes the state
# folder's write permission away.
cat > "$tmp/bin/omarchy-plugin-validate" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$tmp/validated.log"
sed -n 's/^request //p' "\$XDG_STATE_HOME/omanotes/update" >> "$tmp/validate-request.log"
[[ -e "$tmp/validate-fails" ]] && { echo "manifest.json: bad entry point" >&2; exit 1; }
[[ -e "$tmp/validate-hangs" ]] && { touch "$tmp/validating"; sleep 30; }
[[ -e "$tmp/validate-locks-state" ]] && chmod 555 "\$XDG_STATE_HOME/omanotes"
exit 0
SH
# Every git the script starts: whether it inherited the lock's fd 9, and the
# ssh command a fetch runs with.
real_git="$(command -v git)"
mkdir "$tmp/gitbin"
cat > "$tmp/gitbin/git" <<SH
#!/usr/bin/env bash
[[ -e /proc/\$\$/fd/9 ]] && printf '%s\n' "\$*" >> "$tmp/git-fd9.log"
[[ " \$* " == *" fetch "* ]] && printf '%s\n' "\${GIT_SSH_COMMAND:-}" >> "$tmp/git-ssh.log"
exec "$real_git" "\$@"
SH
chmod +x "$tmp/bin/"* "$tmp/gitbin/git"
plain_path="$tmp/bin:$PATH"
export PATH="$tmp/gitbin:$plain_path"
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
run() { bash "$1/data/update.sh" "$2" "$1" "${@:3}"; }
head_of() { git -C "$1" rev-parse HEAD; }
# Every path of the work tree outside .git with its mtime and size: a write
# anywhere the shell's plugin watcher looks changes it.
listing() { find "$1" -path "$1/.git" -prune -o -printf '%P %T@ %s\n' | sort; }

git init --quiet --bare -b main "$tmp/origin.git"
git clone --quiet "$tmp/origin.git" "$tmp/dev" 2> /dev/null
mkdir "$tmp/dev/data"
cp "$worktree/data/update.sh" "$tmp/dev/data/update.sh"
printf '{\n  "id": "othavi0.omanotes",\n  "version": "1.0.0"\n}\n' > "$tmp/dev/manifest.json"
for i in $(seq 200); do echo "$i" > "$tmp/dev/file-$i.txt"; done
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

replies "status on a clean clone names the version, the branch, the whole head and no local changes" \
  "$(run "$plugin" status | tr '\n' '|')" "git 1|version 1.0.0|branch main|head $first|dirty 0|"
replies "a check with nothing new records it up to date" "$(run "$plugin" check; record)" \
  "phase checked|head $first|branch main|behind 0|error |detail |step |from |to $first|request |"
replies "a fetch runs ssh in batch mode, since nobody can answer a prompt" "$(tail -n 1 "$tmp/git-ssh.log")" "ssh -oBatchMode=yes"

publish "fix: busca ignora acento no corpo" "second"
publish $'feat: "aspas" e\ttab no assunto' "third"
second="$(git -C "$tmp/dev" rev-parse HEAD~1)"
third="$(git -C "$tmp/dev" rev-parse HEAD)"
run "$plugin" check
replies "a check counts two new commits on origin/main" "$(field behind)|$(field error)|$(field to)" "2||$third"
replies "and lists them newest first, whole hashes, subjects kept whole" "$(grep '^commit ' "$state" | tr '\n' '|')" \
  "commit $third feat: \"aspas\" e"$'\t'"tab no assunto|commit $second fix: busca ignora acento no corpo|"
replies "a check fetches only into .git, so the plugin folder is untouched" "$(head_of "$plugin")|$(cat "$plugin/notes.txt")" "$first|first"

git -C "$plugin" remote set-url origin "$tmp/gone.git"
run "$plugin" check
replies "a check that cannot reach origin says offline, with git's reason" "$(field error)|$(field detail | grep -c "gone.git" || true)" "offline|1"
replies "and keeps what the last fetch already knew" "$(field behind)|$(grep -c '^commit ' "$state")|$(field to)" "2|2|$third"
git -C "$plugin" remote set-url origin "$tmp/origin.git"

echo "local edit" >> "$plugin/notes.txt"
run "$plugin" check
replies "a check on a folder with local changes says so" "$(field behind)|$(field error)" "2|dirty"
replies "status shows the local changes" "$(run "$plugin" status | grep '^dirty')" "dirty 1"
code=0
run "$plugin" apply req-dirty || code=$?
replies "apply refuses a folder with local changes, records why and exits 0 once recorded" "$(field phase)|$(field error)|$code" "failed|dirty|0"
replies "and its record names the request that asked for it" "$(field request)" "req-dirty"
replies "and touches neither the head nor the changed file" "$(head_of "$plugin")|$(tail -n 1 "$plugin/notes.txt")" "$first|local edit"
replies "nothing was announced" "$(cat "$tmp/omarchy-notification-send.log" 2> /dev/null | wc -l)" "0"
git -C "$plugin" checkout --quiet -- notes.txt

echo "mine" > "$tmp/dev/new.txt"
git -C "$tmp/dev" add new.txt
git -C "$tmp/dev" commit --quiet -m "feat: new.txt"
git -C "$tmp/dev" push --quiet origin main
echo "untracked, not tracked yet" > "$plugin/new.txt"
run "$plugin" check
replies "a check names an untracked file that origin/main would overwrite" "$(field behind)|$(field error)|$(field detail)" "3|untracked|new.txt"
run "$plugin" apply || true
replies "apply refuses it before touching anything" "$(field phase)|$(field error)|$(head_of "$plugin")|$(cat "$plugin/new.txt")" \
  "failed|untracked|$first|untracked, not tracked yet"
rm "$plugin/new.txt"
git -C "$tmp/dev" rm --quiet new.txt
mkdir "$tmp/dev/sub"
echo "theirs" > "$tmp/dev/sub/a.txt"
echo "theirs" > "$tmp/dev/deep"
git -C "$tmp/dev" add sub deep
git -C "$tmp/dev" commit --quiet -m "feat: sub/a.txt e deep"
git -C "$tmp/dev" push --quiet origin main
echo "mine" > "$plugin/sub"
run "$plugin" check
replies "an untracked file where origin/main adds a folder blocks the update and is named" "$(field error)|$(field detail)" "untracked|sub"
rm "$plugin/sub"
mkdir "$plugin/deep"
echo "mine" > "$plugin/deep/mine.txt"
run "$plugin" apply || true
replies "an untracked file inside a folder where origin/main adds a file is refused and named" \
  "$(field phase)|$(field error)|$(field detail)|$(head_of "$plugin")|$(cat "$plugin/deep/mine.txt")" "failed|untracked|deep/mine.txt|$first|mine"
rm -r "$plugin/deep"
git -C "$tmp/dev" rm --quiet -r sub deep
git -C "$tmp/dev" commit --quiet -m "chore: sem sub e deep"
git -C "$tmp/dev" push --quiet origin main
third="$(head_of "$tmp/dev")"

touch "$plugin/.git/index.lock"
run "$plugin" apply || true
rm "$plugin/.git/index.lock"
replies "a merge that git refuses is recorded as such, with git's reason, and the head stays" \
  "$(field phase)|$(field error)|$(field detail | grep -c "index.lock" || true)|$(head_of "$plugin")" "failed|mergeFailed|1|$first"

touch "$tmp/validate-fails"
before="$(listing "$plugin")"
run "$plugin" apply || true
rm "$tmp/validate-fails"
replies "an update that does not validate is recorded as invalid, with the validator's reason" \
  "$(field phase)|$(field error)|$(field detail)" "failed|invalid|manifest.json: bad entry point"
replies "and leaves the head where it was" "$(head_of "$plugin")" "$first"
replies "and writes nothing in the plugin folder, whose watcher would reload the shell" \
  "$(diff <(printf '%s\n' "$before") <(listing "$plugin") | grep -c '^[<>]' || true) paths changed" "0 paths changed"
replies "the validator ran on a copy outside the plugin folder" "$(tail -n 1 "$tmp/validated.log" | grep -c "^$plugin" || true)" "0"

: > "$tmp/validate-request.log"
run "$plugin" apply req-pull || true
replies "apply on a clean folder fast-forwards to origin/main" "$(head_of "$plugin")" "$third"
replies "every record the apply wrote names its request, the one it left before validating and the last" \
  "$(cat "$tmp/validate-request.log")|$(field request)" "req-pull|req-pull"
replies "and records the update from the old head to the new one" \
  "$(field phase)|$(field from)|$(field to)|$(field head)|$(field behind)|$(field error)|$(field step)" "updated|$first|$third|$third|5||"
replies "the script never asks the shell to reload: its plugin watcher does" "$(cat "$tmp/omarchy-shell.log" 2> /dev/null | wc -l)" "0"
replies "and one notification names the change" "$(cat "$tmp/omarchy-notification-send.log")" \
  "Omanotes updated $(git -C "$plugin" rev-parse --short "$first") → $(git -C "$plugin" rev-parse --short "$third") · 5 commits"
run "$plugin" check
replies "a check right after keeps the update as the news" "$(field phase)|$(field to)|$(field behind)|$(field error)" "updated|$third|5|"
replies "and its record names no request" "$(field request)" ""
replies "no git the script started held the lock" "$(cat "$tmp/git-fd9.log" 2> /dev/null | wc -l)" "0"

# `status` from several panels at once while apply merges: none of them may
# take index.lock from under the merge. The real git, so the loops run at
# full speed.
rounds=0
for round in 1 2 3 4 5 6 7 8; do
  publish "feat: rodada $round" "round $round"
  touch "$tmp/go"
  for _ in 1 2 3 4; do ( while [[ -e "$tmp/go" ]]; do PATH="$plain_path" run "$plugin" status > /dev/null; done ) & done
  sleep 0.2
  PATH="$plain_path" run "$plugin" apply || true
  rm "$tmp/go"
  wait
  [[ "$(field phase)" == updated && "$(head_of "$plugin")" == "$(head_of "$tmp/dev")" ]] && rounds=$((rounds + 1))
done
replies "eight applies with four status loops running each end updated" "$rounds" "8"
third="$(head_of "$plugin")"

git -C "$plugin" remote remove origin
run "$plugin" check
replies "a clone without origin says so" "$(field error)" "noOrigin"
git -C "$plugin" remote add origin "$tmp/origin.git"

publish "feat: quarto" "fourth"
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
exec 8> "$tmp/state/omanotes/update.lock"
flock 8
run "$plugin" apply 8>&- & waiting=$!
sleep 1
replies "an apply waits while another holds the lock, and pulls nothing yet" "$(kill -0 "$waiting" 2> /dev/null && echo waiting)|$(head_of "$plugin")" "waiting|$third"
exec 8>&-
code=0
wait "$waiting" || code=$?
replies "then takes its turn and ends updated" "$code|$(field phase)|$(head_of "$plugin")" "0|updated|$(head_of "$tmp/dev")"

sed -i '2i # The whole script is read first, so this line moves every line below it.' "$tmp/dev/data/update.sh"
git -C "$tmp/dev" commit --quiet -am "chore: o script de update muda a si mesmo"
git -C "$tmp/dev" push --quiet origin main
newest="$(head_of "$tmp/dev")"
run "$plugin" apply || true
replies "an update that rewrites the update script itself still ends updated" "$(field phase)|$(field to)|$(head_of "$plugin")" "updated|$newest|$newest"
replies "with the new script in place" "$(grep -c "The whole script is read first" "$plugin/data/update.sh")" "1"

# systemd stops the unit with SIGTERM to all of it, on RuntimeMaxSec among
# others: the copy being validated goes with it.
publish "feat: sexto" "sixth"
touch "$tmp/validate-hangs"
setsid bash "$plugin/data/update.sh" apply "$plugin" & unit=$!
for _ in $(seq 100); do [[ -e "$tmp/validating" ]] && break; sleep 0.1; done
tree="$(tail -n 1 "$tmp/validated.log")"
kill -TERM -- "-$unit"
wait "$unit" || true
rm "$tmp/validate-hangs"
replies "an apply stopped while it validates removes its copy" "$([[ -n "$tree" && ! -e "$tree" ]] && echo removed || echo "left $tree")" "removed"
replies "and pulls nothing" "$(head_of "$plugin")" "$newest"

touch "$tmp/validate-locks-state"
code=0
run "$plugin" apply || code=$?
chmod 755 "$tmp/state/omanotes"
rm "$tmp/validate-locks-state"
replies "an apply that pulls but cannot record it exits 1" "$code|$(head_of "$plugin")" "1|$(head_of "$tmp/dev")"

echo "update: $checks checks, $failures failed"
exit $(( failures > 0 ))
