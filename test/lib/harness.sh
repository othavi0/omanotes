# Sourced by the offscreen Quickshell scripts in test/. Builds a
# throwaway `qs -p` config dir (kit symlinked from the installed shell, ui/ and
# data/ from this checkout) and a throwaway XDG_DATA_HOME holding a seeded
# scratchpad.db at the current schema version. The rows are written at version
# 0 and then migrated, as the items of a database from before versioning are.

worktree="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
shell_root="${OMARCHY_PATH:-/usr/share/omarchy}/shell"

missing=()
for cmd in qs sqlite3 node timeout; do
  command -v "$cmd" > /dev/null || missing+=("$cmd")
done
[[ -d "$shell_root/Commons" && -d "$shell_root/Ui" ]] || missing+=("Omarchy shell at $shell_root (set OMARCHY_PATH)")
if (( ${#missing[@]} > 0 )); then
  printf 'missing prerequisite: %s\n' "${missing[@]}" >&2
  exit 2
fi

cfg_dir="$(mktemp -d)"
data_home="$(mktemp -d)"
trap 'rm -rf "$cfg_dir" "$data_home"' EXIT

ln -s "$shell_root/Commons" "$cfg_dir/Commons"
ln -s "$shell_root/Ui" "$cfg_dir/Ui"
ln -s "$worktree/ui" "$cfg_dir/ui"
ln -s "$worktree/data" "$cfg_dir/data"

mkdir -p "$data_home/omarchy"
db="$data_home/omarchy/scratchpad.db"
# The binary of this checkout, under the name the Store resolves next to data/.
# A script that wants to hold, fail or count requests replaces the link with
# lib/stub-db.sh (see stub_db below).
arch="$(uname -m)"
real_db="$worktree/bin/omanotes-db.$arch"
mkdir -p "$cfg_dir/bin"
ln -s "$real_db" "$cfg_dir/bin/omanotes-db.$arch"
# The Store finds the binary at ../bin/ from its own data/Store.qml. A script that loads
# the plugin from the checkout (BarWidget.qml, Service.qml by URL) gets a farm of links to
# the checkout with a bin/ of its own that holds the stub, and runs the shell on that
# ($stub_tree). Scripts that load the plugin from $cfg_dir/data need only $cfg_dir/bin.
stub_db() {
  rm -f "$cfg_dir/bin/omanotes-db.$arch"
  sed "s#@CFG@#$cfg_dir#; s#@REAL@#$real_db#" "$worktree/test/lib/stub-db.sh" > "$cfg_dir/bin/omanotes-db.$arch"
  chmod +x "$cfg_dir/bin/omanotes-db.$arch"
  stub_tree="$cfg_dir/tree"
  mkdir -p "$stub_tree"
  local entry
  for entry in "$worktree"/*; do
    [[ "$(basename "$entry")" == bin ]] || ln -sfn "$entry" "$stub_tree/$(basename "$entry")"
  done
  ln -sfn "$cfg_dir/bin" "$stub_tree/bin"
}
# A wl-copy for the Updates page's Copy, at $cfg_dir/wl-copy: it logs its
# arguments, the names in the environment it was given and its stdin in clipboard.log, and fails
# with the text of wl-copy-fails while that file exists.
stub_wl_copy() {
  cat > "$cfg_dir/wl-copy" <<SH
#!$(command -v bash)
if [[ -e "$cfg_dir/wl-copy-fails" ]]; then cat "$cfg_dir/wl-copy-fails" >&2; exit 1; fi
{ echo "args=\$# wayland=\${WAYLAND_DISPLAY-unset} runtime=\${XDG_RUNTIME_DIR-unset} env=\$(tr '\\0' '\\n' < /proc/\$\$/environ | cut -d= -f1 | sort | paste -sd,)"; printf 'stdin=[%s]\n' "\$(cat)"; } >> "$cfg_dir/clipboard.log"
SH
  chmod +x "$cfg_dir/wl-copy"
}
# lib/stall-journal.c, built where the stub preloads it. Returns 1 with no C compiler.
stall_journal_lib() {
  command -v cc > /dev/null || return 1
  cc -shared -fPIC -O2 -o "$cfg_dir/stall-journal.so" "$worktree/test/lib/stall-journal.c" -ldl
}
# The protocol the QML speaks, for the requests a script sends the binary itself.
protocol="$(sed -n 's/^var PROTOCOL = \([0-9]*\)$/\1/p' "$worktree/data/Db.js")"
# One sync of the whole file, which opening it with the binary migrates first.
sync_db() { "$real_db" "$protocol" run "$1" <<< '{"sync":{}}'; }
# `v0_db` writes the schema of version 0 (lib/v0.sql), on which the rows go;
# `migrate_db` takes the file to the current version.
v0_db() { sqlite3 "$db" < "$worktree/test/lib/v0.sql"; }
migrate_db() { sync_db "$db" > /dev/null; }
v0_db

now="$(date +%s)"
sqlite3 "$db" "INSERT INTO items (id, type, title, body, status, created_at, updated_at) VALUES
  (1, 'note', 'Ideas for the panel', 'Tabs the same width, wide search.' || char(10) || 'Shortcut legend never cut off.', 0, $now - 3600, $now - 3600),
  (2, 'todo', 'Renew the domain', 'Due day 30. Check the card on file first.', 0, $now - 720, $now - 720),
  (3, 'todo', 'Reply to upstream PR review', '', 0, $now - 10800, $now - 10800),
  (4, 'note', 'Buy coffee', 'Medium grind, 500g.', 1, $now - 90000, $now - 90000),
  (5, 'todo', 'Backup scratchpad.db', '', 1, $now - 172800, $now - 172800),
  (6, 'note', 'ThinkPad lid measurements', '', 1, $now - 432000, $now - 432000);
INSERT INTO history (id, type, title, action, ts) VALUES
  (1, 'todo', 'Renew the domain', 'added', $now - 720),
  (2, 'note', 'Buy coffee', 'completed', $now - 90000),
  (3, 'todo', 'Old errand', 'deleted', $now - 100000),
  (4, 'note', 'Ideas for the panel', 'edited', $now - 3600);"
migrate_db

# A plain command, so a caller that backgrounds it gets the pid of `timeout`
# in `$!`; killing that pid then reaches qs.
qs_cmd=(env XDG_DATA_HOME="$data_home" QT_QPA_PLATFORM=offscreen timeout 120 qs -p "$cfg_dir")
run_qs() { "${qs_cmd[@]}" "$@"; }

# The kit's KeyboardPanel is a layer-shell PanelWindow, which has no backend
# offscreen, so the Panel would fail to load. Swap in a plain window with the
# API Panel.qml uses; the rest of the kit stays the installed one.
stub_keyboard_panel() {
  rm "$cfg_dir/Ui"
  mkdir "$cfg_dir/Ui"
  ln -s "$shell_root"/Ui/* "$cfg_dir/Ui/"
  rm "$cfg_dir/Ui/KeyboardPanel.qml"
  cat > "$cfg_dir/Ui/KeyboardPanel.qml" <<'QML'
import QtQuick
import Quickshell

FloatingWindow {
  required property Item anchorItem
  required property QtObject bar
  property var owner: null
  property bool open: false
  property int contentWidth
  property int contentHeight
  property Item focusTarget: null
  default property alias contentItem: holder.children
  function fittedContentWidth(width) { return width }
  function fittedContentHeight(height) { return height }
  visible: open
  onOpenChanged: if (open && focusTarget) Qt.callLater(function() { if (open && focusTarget) focusTarget.forceActiveFocus() })
  implicitWidth: contentWidth
  implicitHeight: contentHeight
  Item { id: holder; anchors.fill: parent }
}
QML
}
