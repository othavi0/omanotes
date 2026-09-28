#!/usr/bin/env bash
# Omanotes self-update (ADR-0017). Usage: bash update.sh status|check|apply <plugin-dir>
#
# status prints `key value` lines about the checkout and touches nothing.
# check fetches origin/main and records what is new in the state file.
# apply fetches, refuses anything that could lose work, fast-forwards main,
# validates, reloads the shell and records the result.
#
# The state file, ${XDG_STATE_HOME:-~/.local/state}/omanotes/update, is how
# a result outlives the reload: the merge rewrites the plugin folder, the
# shell reloads and destroys whoever started this, and the new panel reads
# the file. It is written whole to a temporary file and moved into place.
# One `key value` per line; only the first space splits a line.

main() {
  local mode="${1:-}" dir="${2:-}"
  export LC_ALL=C GIT_TERMINAL_PROMPT=0
  state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/omanotes"
  state_file="$state_dir/update"
  phase="" error="" detail="" step="" behind=0 from="" to="" commits="" head="" branch=""

  case "$mode" in
    status) status_mode "$dir" ;;
    check) locked_run check_mode "$dir" ;;
    apply) locked_run apply_mode "$dir" ;;
    *) echo "usage: update.sh status|check|apply <plugin-dir>" >&2; return 2 ;;
  esac
}

# A check waits for the lock, so the service's daily check and a click both
# finish. A second apply never waits: it leaves the first one's record alone.
locked_run() {
  mkdir -p "$state_dir" || return 1
  exec 9> "$state_dir/update.lock"
  if [[ "$1" == apply_mode ]]; then
    flock -n 9 || { echo "locked" >&2; return 3; }
  else
    flock -w 60 9 || { echo "locked" >&2; return 3; }
  fi
  "$@"
}

in_git() { git -C "$1" "${@:2}"; }

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
  head="$(in_git "$1" rev-parse --short HEAD 2> /dev/null)"
  branch="$(in_git "$1" symbolic-ref --quiet --short HEAD 2> /dev/null || echo HEAD)"
}

is_dirty() { [[ -n "$(in_git "$1" status --porcelain --untracked-files=no 2> /dev/null)" ]]; }

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
    printf 'phase %s\nat %s\nhead %s\nbranch %s\nbehind %s\nerror %s\ndetail %s\nstep %s\nfrom %s\nto %s\n' \
      "$phase" "$(date +%s)" "$head" "$branch" "$behind" "$error" "$detail" "$step" "$from" "$to"
    [[ -n "$commits" ]] && printf '%s\n' "$commits"
  } > "$tmp"
  mv -f -- "$tmp" "$state_file"
}

# git's own reason: its first fatal or error line, else its last line.
first_error() {
  printf '%s\n' "$1" | grep -m 1 -E '^(fatal|error):' || printf '%s\n' "$1" | tail -n 1
}

# Fetches origin's main into origin/main. Sets error and detail on failure.
fetch() {
  local dir="$1" out
  if ! in_git "$dir" remote get-url origin > /dev/null 2>&1; then
    error="noOrigin"
    return 1
  fi
  if ! out="$(timeout 20 git -C "$dir" fetch --quiet origin +refs/heads/main:refs/remotes/origin/main 2>&1)"; then
    error="offline"
    detail="$(first_error "$out")"
    return 1
  fi
}

# What is new on origin/main, and the first thing that keeps apply from
# pulling it.
survey() {
  local dir="$1"
  behind="$(in_git "$dir" rev-list --count HEAD..origin/main)"
  commits="$(in_git "$dir" log --format='commit %h %s' -n 20 HEAD..origin/main)"
  if is_dirty "$dir"; then error="dirty"
  elif [[ "$branch" != main ]]; then error="offMain"
  elif ! in_git "$dir" merge-base --is-ancestor HEAD origin/main; then error="diverged"
  fi
}

check_mode() {
  local dir="$1"
  phase="checked"
  if ! is_checkout "$dir"; then
    error="notGit"
    write_state
    return 0
  fi
  read_local "$dir"
  fetch "$dir" && survey "$dir"
  write_state
}

apply_mode() {
  local dir="$1" out
  if ! is_checkout "$dir"; then
    phase="failed" error="notGit"
    write_state
    return 1
  fi
  read_local "$dir"
  phase="updating" step="fetch"
  write_state
  if ! fetch "$dir"; then
    phase="failed" step=""
    write_state
    return 1
  fi
  survey "$dir"
  if [[ -n "$error" ]]; then
    phase="failed" step=""
    write_state
    return 1
  fi
  if (( behind == 0 )); then
    phase="checked" step=""
    write_state
    return 0
  fi
  from="$head" to="$(in_git "$dir" rev-parse --short origin/main)" step="pull"
  write_state
  if ! out="$(in_git "$dir" merge --ff-only --quiet origin/main 2>&1)"; then
    phase="failed" error="diverged" detail="$(printf '%s\n' "$out" | tail -n 1)" step=""
    write_state
    return 1
  fi
  # The host's own updater rolls back the same way when the new code does
  # not validate.
  if command -v omarchy-plugin-validate > /dev/null 2>&1 && ! out="$(omarchy-plugin-validate "$dir" 2>&1)"; then
    in_git "$dir" reset --quiet --hard ORIG_HEAD
    read_local "$dir"
    phase="failed" error="invalid" detail="$(printf '%s\n' "$out" | tail -n 1)" step=""
    write_state
    return 1
  fi
  read_local "$dir"
  step="reload"
  write_state
  command -v omarchy-shell > /dev/null 2>&1 && omarchy-shell shell rescanPlugins > /dev/null 2>&1
  phase="updated" step=""
  write_state
  command -v omarchy-notification-send > /dev/null 2>&1 \
    && omarchy-notification-send "Omanotes updated" "$from → $to · $behind commit$( (( behind == 1 )) || echo s)"
  return 0
}

# One line, so bash has read the whole script before the merge rewrites it.
main "$@"; exit $?
