# Sourced by test/render.sh and test/behavior.sh. Builds a throwaway `qs -p`
# config dir (kit symlinked from the installed shell, ui/ and data/ from this
# checkout) and a throwaway XDG_DATA_HOME holding a seeded scratchpad.db.

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
node --input-type=module -e '
  const { loadQmlLib } = await import(process.argv[1])
  process.stdout.write(loadQmlLib(process.argv[2], ["SCHEMA"]).SCHEMA)
' "$worktree/test/lib/load-qml-lib.mjs" "$worktree/data/Db.js" | sqlite3 "$db"

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


run_qs() {
  XDG_DATA_HOME="$data_home" QT_QPA_PLATFORM=offscreen timeout 60 qs -p "$cfg_dir" "$@"
}
