#!/usr/bin/env bash
# Omanotes self-update (ADR-0017).
# Usage: bash update.sh status|check <plugin-dir>, or apply <plugin-dir> [request]
#
# status prints `key value` lines about the checkout and touches nothing.
# check fetches origin/main and records what is new in the state file.
# apply fetches, refuses anything that could lose work, validates origin/main
# in a copy outside the plugin folder and only then fast-forwards main. Then
# it restarts the shell, the only way the shell loads the new code, and
# notifies.
#
# The state file, ${XDG_STATE_HOME:-~/.local/state}/omanotes/update, is how
# a result outlives the reload and the restart: the merge rewrites the plugin
# folder, the shell's watcher reloads the plugin and destroys whoever started
# this, the restart replaces the shell, and the new panel reads the file. It
# is written whole to a temporary file and moved into place.
# One `key value` per line; only the first space splits a line. Hashes are
# whole; the panel shortens them. Every record apply writes carries the
# request it was started with, so the panel that asked tells its own apply's
# records from a check's.
#
# Exits 0 once a result is recorded, a refusal or a failed restart included,
# 3 when the lock stayed taken and 1 when nothing could be recorded or an
# update that landed could not be.

main() {
  local mode="${1:-}" dir="${2:-}"
  request="${3:-}"
  # Optional locks off: several panels run `status` at any moment, and a
  # `git status` holding index.lock makes the merge fail.
  export LC_ALL=C GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0
  state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/omanotes"
  state_file="$state_dir/update"
  phase="" error="" detail="" step="" behind=0 from="" to="" commits="" head="" branch="" work=""

  case "$mode" in
    status) status_mode "$dir" ;;
    check) locked_run check_mode "$dir" ;;
    apply) locked_run apply_mode "$dir" ;;
    *) echo "usage: update.sh status|check|apply <plugin-dir> [request]" >&2; return 2 ;;
  esac
}

# The service's daily check, a click in any panel and an apply take turns.
# Every command below runs with fd 9 closed (9>&-), so nothing it leaves
# behind, such as a detached `git gc`, keeps holding the lock.
locked_run() {
  mkdir -p "$state_dir" || return 1
  exec 9> "$state_dir/update.lock" || return 1
  flock -w 60 9 || { echo "locked" >&2; return 3; }
  "$@"
}

in_git() { git -C "$1" "${@:2}" 9>&-; }

# True when `dir` is the top of its own work tree. A copy inside some other
# repository counts as no checkout, so an update never pulls a parent repo.
is_checkout() {
  local dir="$1" top real
  real="$(cd "$dir" 2> /dev/null && pwd -P)" || return 1
  top="$(in_git "$dir" rev-parse --show-toplevel 2> /dev/null)" || return 1
  [[ "$(cd "$top" && pwd -P)" == "$real" ]]
}

version_of() {
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1/manifest.json" 2> /dev/null | head -n 1
}

read_local() {
  head="$(in_git "$1" rev-parse HEAD 2> /dev/null)"
  branch="$(in_git "$1" symbolic-ref --quiet --short HEAD 2> /dev/null || echo HEAD)"
}

is_dirty() { [[ -n "$(in_git "$1" status --porcelain --untracked-files=no 2> /dev/null)" ]]; }

# The first untracked path the merge would refuse to overwrite: one that
# origin/main tracks, one where it tracks a folder, or one inside a path it
# tracks as a file. Ignored files are left out, since git overwrites them.
collision() {
  awk 'NR == FNR { tracked[$0] = 1; p = $0; while (sub(/\/[^\/]*$/, "", p)) folders[p] = 1; next }
    ($0 in tracked) || ($0 in folders) { print; exit }
    { p = $0; while (sub(/\/[^\/]*$/, "", p)) if (p in tracked) { print $0; exit } }' \
    <(in_git "$1" ls-tree -r --name-only origin/main) <(in_git "$1" ls-files --others --exclude-standard)
}

status_mode() {
  local dir="$1"
  if ! is_checkout "$dir"; then
    printf 'git 0\nversion %s\n' "$(version_of "$dir")"
    return 0
  fi
  read_local "$dir"
  printf 'git 1\nversion %s\nbranch %s\nhead %s\ndirty %s\n' "$(version_of "$dir")" "$branch" "$head" "$(is_dirty "$dir" && echo 1 || echo 0)"
}

write_state() {
  local tmp
  tmp="$(mktemp "$state_dir/.update.XXXXXX")" || return 1
  {
    printf 'phase %s\nat %s\nhead %s\nbranch %s\nbehind %s\nerror %s\ndetail %s\nstep %s\nfrom %s\nto %s\nrequest %s\n' \
      "$phase" "$(date +%s)" "$head" "$branch" "$behind" "$error" "$detail" "$step" "$from" "$to" "$request"
    if [[ -n "$commits" ]]; then printf '%s\n' "$commits"; fi
  } > "$tmp" || return 1
  mv -f -- "$tmp" "$state_file"
}

# The value of `key` in the state file as it is now.
recorded() { sed -n "s/^$1 //p" "$state_file" 2> /dev/null | head -n 1; }

# A tool's own reason: its first fatal or error line, else its last line.
first_error() {
  printf '%s\n' "$1" | grep -m 1 -E '^(fatal|error):' || printf '%s\n' "$1" | tail -n 1
}

# Fetches origin's main into origin/main. Sets error and detail on failure.
# ssh runs in batch mode, on top of the user's own ssh command: an apply has
# no terminal to answer a prompt.
fetch() {
  local dir="$1" out ssh
  if ! in_git "$dir" remote get-url origin > /dev/null 2>&1; then
    error="noOrigin"
    return 1
  fi
  ssh="${GIT_SSH_COMMAND:-$(in_git "$dir" config core.sshCommand || echo ssh)}"
  if ! out="$(GIT_SSH_COMMAND="$ssh -oBatchMode=yes" timeout 20 git -C "$dir" fetch --quiet origin +refs/heads/main:refs/remotes/origin/main 2>&1 9>&-)"; then
    error="offline"
    detail="$(first_error "$out")"
    return 1
  fi
}

# What is new on origin/main, and the first thing that keeps apply from
# pulling it.
survey() {
  local dir="$1" clash
  to="$(in_git "$dir" rev-parse --verify --quiet origin/main)"
  behind="$(in_git "$dir" rev-list --count HEAD..origin/main)"
  commits="$(in_git "$dir" log --format='commit %H %s' -n 20 HEAD..origin/main)"
  if is_dirty "$dir"; then error="dirty"
  elif [[ "$branch" != main ]]; then error="offMain"
  elif ! in_git "$dir" merge-base --is-ancestor HEAD origin/main; then error="diverged"
  elif (( behind > 0 )) && clash="$(collision "$dir")" && [[ -n "$clash" ]]; then error="untracked" detail="$clash"
  fi
}

check_mode() {
  local dir="$1" was
  phase="checked"
  if ! is_checkout "$dir"; then
    error="notGit"
    write_state
    return
  fi
  read_local "$dir"
  if fetch "$dir"; then
    survey "$dir"
  elif [[ "$error" == offline ]] && in_git "$dir" rev-parse --verify --quiet origin/main > /dev/null; then
    # What the last fetch brought is still true.
    was="$detail"
    survey "$dir"
    error="offline" detail="$was"
  fi
  # The update that just landed stays the news until something newer shows up.
  if [[ -z "$error" ]] && (( behind == 0 )) && [[ "$(recorded phase)" == updated && "$(recorded to)" == "$head" ]]; then
    phase="updated" from="$(recorded from)" behind="$(recorded behind)"
  fi
  write_state
}

# Checks origin/main as the shell would load it, in a copy outside the plugin
# folder, so a version that does not validate never touches the folder. The
# copy lives beside the state file rather than in /tmp, which is often
# mounted noexec: the smoke has to run the binary on the file system the
# plugin runs it from. The copy goes on any exit, including the SIGTERM
# systemd stops the unit with, and one a SIGKILL left goes with the next
# apply, which holds the lock.
validate() {
  local dir="$1" out
  detail=""
  trap 'exit 143' TERM INT HUP
  trap '[[ -z "$work" ]] || rm -rf -- "$work"' EXIT
  rm -rf -- "$state_dir"/validate.*
  work="$(mktemp -d "$state_dir/validate.XXXXXX")" || { detail="could not make a temporary folder"; return 1; }
  if ! out="$(set -o pipefail; mkdir "$work/tree" && { in_git "$dir" archive "$to" | tar -x -C "$work/tree"; } 2>&1)"; then
    detail="$(first_error "$out")"
  elif command -v omarchy-plugin-validate > /dev/null 2>&1 && ! out="$(omarchy-plugin-validate "$work/tree" 2>&1 9>&-)"; then
    detail="$(printf '%s\n' "$out" | tail -n 1)"
  else
    smoke_db "$work"
  fi
  rm -rf -- "$work"
  work=""
  [[ -z "$detail" ]]
}

# The ELF e_machine of each machine omanotes-db is built for, as `uname -m`
# names it.
elf_machine_of() {
  case "$1" in
    x86_64) echo 62 ;;
    aarch64) echo 183 ;;
  esac
}

# The e_machine field of an ELF file's header, or nothing when it is no ELF.
elf_machine() {
  local -a b
  read -r -a b < <(od -An -v -tu1 -N20 "$1" 2> /dev/null | tr '\n' ' ')
  (( ${#b[@]} == 20 )) && [[ "${b[*]:0:4}" == "127 69 76 70" ]] || return 0
  case "${b[5]}" in
    1) echo $(( b[18] + 256 * b[19] )) ;;
    2) echo $(( 256 * b[18] + b[19] )) ;;
  esac
}

# Proves the copy's omanotes-db runs on this machine and speaks the protocol
# of the copy's data/Db.js (ADR-0018), since the merge would put the plugin
# in a shell that cannot read its database. The machine is read from the ELF
# header because running it proves nothing: with qemu's binfmt an aarch64
# binary starts on x86_64. Sets detail on failure.
smoke_db() {
  local work="$1" arch name bin want got proto code=0 out reason
  arch="$(uname -m)"
  name="bin/omanotes-db.$arch"
  bin="$work/tree/$name"
  want="$(elf_machine_of "$arch")"
  proto="$(sed -n 's/^var PROTOCOL = \([0-9][0-9]*\);\{0,1\}[[:space:]]*$/\1/p' "$work/tree/data/Db.js" 2> /dev/null | head -n 1)"
  if [[ ! -e "$bin" && ! -L "$bin" ]]; then detail="there is no $name"
  elif [[ -L "$bin" || ! -f "$bin" ]]; then detail="$name is not a regular file"
  elif [[ ! -x "$bin" ]]; then detail="$name is not executable"
  elif [[ -z "$want" ]]; then detail="no ELF machine is known for $arch"
  elif got="$(elf_machine "$bin")" && [[ "$got" != "$want" ]]; then detail="$name is built for ELF machine ${got:-none}, not $arch"
  elif [[ -z "$proto" ]]; then detail="data/Db.js declares no PROTOCOL"
  else
    # An empty environment, as the Lane starts it: a DOTNET_* variable
    # changes the runtime.
    out="$(timeout 20 env -i "$bin" "$proto" selftest "$work/selftest" 2>&1 > /dev/null 9>&-)" || code=$?
    reason="$(printf '%s\n' "$out" | tail -n 1)"
    reason="${reason//"$work/tree/"/}"
    [[ "$reason" =~ ^\{\"err\":\"[^\"]*\",\"detail\":\"(.*)\"\}$ ]] && reason="${BASH_REMATCH[1]}"
    case "$code" in
      0) ;;
      64) detail="omanotes-db does not speak protocol $proto of data/Db.js" ;;
      124) detail="omanotes-db selftest did not finish in 20 s" ;;
      *) detail="omanotes-db selftest failed with exit $code${reason:+: $reason}" ;;
    esac
  fi
}

apply_mode() {
  local dir="$1" out
  if ! is_checkout "$dir"; then
    phase="failed" error="notGit"
    write_state
    return
  fi
  read_local "$dir"
  phase="updating" step="fetch"
  write_state || return 1
  if ! fetch "$dir"; then
    phase="failed" step=""
    write_state
    return
  fi
  survey "$dir"
  if [[ -n "$error" ]]; then
    phase="failed" step=""
    write_state
    return
  fi
  if (( behind == 0 )); then
    phase="checked" step=""
    write_state
    return
  fi
  from="$head" step="validate"
  write_state
  if ! validate "$dir"; then
    phase="failed" error="invalid" step=""
    write_state
    return
  fi
  step="pull"
  write_state
  if ! out="$(in_git "$dir" merge --ff-only --quiet "$to" 2>&1)"; then
    phase="failed" error="mergeFailed" detail="$(first_error "$out")" step=""
    read_local "$dir"
    write_state
    return
  fi
  read_local "$dir"
  phase="updated" step="restart"
  local recorded=0 news
  write_state || recorded=1
  restart_shell
  step=""
  write_state || recorded=1
  news="$(in_git "$dir" rev-parse --short "$from") → $(in_git "$dir" rev-parse --short "$to") · $behind commit$( (( behind == 1 )) || echo s)"
  [[ -z "$error" ]] || news="$news. Run omarchy restart shell to load it."
  command -v omarchy-notification-send > /dev/null 2>&1 && omarchy-notification-send "Omanotes updated" "$news" 9>&-
  return "$recorded"
}

# The watcher's reload recreates the plugin from the components the shell
# already compiled, so only a new shell loads the pulled code. This unit is
# outside the shell and survives it. Sets error and detail on failure.
restart_shell() {
  local out
  if ! command -v omarchy-restart-shell > /dev/null 2>&1; then
    error="restartFailed" detail="omarchy-restart-shell not found"
  elif ! out="$(omarchy-restart-shell 2>&1 > /dev/null 9>&-)"; then
    error="restartFailed" detail="$(printf '%s\n' "$out" | head -n 1)"
  fi
}

# One line, so bash has read the whole script before the merge rewrites it.
main "$@"; exit $?
