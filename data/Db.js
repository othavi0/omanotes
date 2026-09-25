.pragma library

// Omanotes SQL builders + result parsers. Deliberately Quickshell-free (no
// `Quickshell.*`, no QML types) so it's exercised directly under Node (see
// test/db.test.mjs). Owns all SQL for the plugin — Db.qml calls these
// builders instead of building SQL ad hoc.

// Quote a JS string as a single-quoted SQL literal, doubling embedded quotes.
function q(value) {
  return "'" + String(value).replace(/'/g, "''") + "'"
}

// Escape a substring for use inside a LIKE pattern with backslash escaping.
// Backslashes must be escaped first so they don't swallow the wildcards.
function likeEscape(s) {
  return String(s).replace(/\\/g, "\\\\").replace(/%/g, "\\%").replace(/_/g, "\\_")
}

// Unix timestamp in seconds.
function now() {
  return Math.floor(Date.now() / 1000)
}

// Unified list. filterType is "all"|"note"|"todo";
// query is an optional case-insensitive substring match on title or body.
// Sort order: pending (unread/in-progress, status 0) always on top, then
// recency — `status ASC, updated_at DESC`.
function listSql(filterType, query) {
  var where = []
  var ft = String(filterType || "all")
  if (ft !== "all") {
    if (ft !== "note" && ft !== "todo") ft = "all"
    else where.push("type = " + q(ft))
  }
  var needle = String(query || "").trim()
  if (needle !== "") {
    var pattern = q("%" + likeEscape(needle) + "%")
    where.push("(title LIKE " + pattern + " ESCAPE '\\' OR body LIKE " + pattern + " ESCAPE '\\')")
  }
  var sql = "SELECT id, type, title, body, status, created_at, updated_at FROM items"
  if (where.length > 0) sql += " WHERE " + where.join(" AND ")
  sql += " ORDER BY status ASC, updated_at DESC, id DESC"
  return sql
}

// Pending counts for the bar tooltip and the panel header: unread notes /
// in-progress todos, plus unfiltered totals per type for the filter segment.
function countsSql() {
  return "SELECT "
    + "(SELECT COUNT(*) FROM items WHERE type = 'note' AND status = 0) AS unreadNotes, "
    + "(SELECT COUNT(*) FROM items WHERE type = 'todo' AND status = 0) AS inProgressTodos, "
    + "(SELECT COUNT(*) FROM items WHERE type = 'note') AS notes, "
    + "(SELECT COUNT(*) FROM items WHERE type = 'todo') AS todos"
}

// One argument per statement: the CLI stops at the first failing argument and
// the open transaction rolls back, while statements joined in one argument keep
// running past a failure (ADR-0001). IMMEDIATE takes the write lock up front.
function transaction(statements) {
  return ["BEGIN IMMEDIATE"].concat(statements, ["COMMIT"])
}

// Insert a new item (status 0) + "added" history row, and return its id.
// The `SELECT last_insert_rowid()` sits between the two INSERTs so it captures
// the items row (a later history INSERT would otherwise move last_insert_rowid).
function addSql(type, title, body) {
  var t = (type === "todo") ? "todo" : "note"
  var ts = now()
  var b = (body === null || body === undefined || body === "") ? "NULL" : q(body)
  return transaction([
    "INSERT INTO items (type, title, body, status, created_at, updated_at) VALUES ("
      + q(t) + ", " + q(title) + ", " + b + ", 0, " + ts + ", " + ts + ")",
    "SELECT last_insert_rowid() AS id",
    "INSERT INTO history (type, title, action, ts) VALUES ("
      + q(t) + ", " + q(title) + ", 'added', " + ts + ")"
  ])
}

// Ids are interpolated into the SQL text (ADR-0002), so anything but a whole
// number is refused before a statement is built.
function sqlId(id) {
  if (!/^\d+$/.test(String(id))) throw new Error("invalid id: " + id)
  return Number(id)
}

// Printed by the writes that target one item, right after the statement that
// changes it: parseFound() reads 0 when no item had that id.
var CHANGES = "SELECT changes()"

// Set an item's status (0 or 1) + record "completed"/"reopened" history.
// The history row is an INSERT…SELECT of the item's own type/title so quoting
// is always correct. It runs first so it can skip an item that already has
// the status, which the UPDATE then leaves as it was.
function setStatusSql(id, status) {
  var s = (status === 1) ? 1 : 0
  var ts = now()
  var action = (s === 1) ? "completed" : "reopened"
  var nid = sqlId(id)
  return transaction([
    "INSERT INTO history (type, title, action, ts) "
      + "SELECT type, title, " + q(action) + ", " + ts + " FROM items WHERE id = " + nid
      + " AND status <> " + s,
    "UPDATE items SET status = " + s + ", updated_at = CASE status WHEN " + s
      + " THEN updated_at ELSE " + ts + " END WHERE id = " + nid,
    CHANGES
  ])
}

// Update an item's title/body (bump updated_at, type is fixed on edit) +
// record an "edited" history row carrying the post-edit title. The history
// INSERT…SELECT reads the item's own type + title after the UPDATE.
function updateSql(id, title, body) {
  var nid = sqlId(id)
  var b = (body === null || body === undefined || body === "") ? "NULL" : q(body)
  var ts = now()
  return transaction([
    "UPDATE items SET title = " + q(title) + ", body = " + b + ", updated_at = " + ts
      + " WHERE id = " + nid,
    CHANGES,
    "INSERT INTO history (type, title, action, ts) "
      + "SELECT type, title, 'edited', " + ts + " FROM items WHERE id = " + nid
  ])
}

// Permanently delete an item + record "deleted" history (title captured first).
function deleteItemSql(id) {
  var ts = now()
  var nid = sqlId(id)
  return transaction([
    "INSERT INTO history (type, title, action, ts) "
      + "SELECT type, title, 'deleted', " + ts + " FROM items WHERE id = " + nid,
    "DELETE FROM items WHERE id = " + nid,
    CHANGES
  ])
}

// Flip an item's type (note<->todo), bump updated_at, keep status, and
// record a "converted" history row.
function convertTypeSql(id) {
  var nid = sqlId(id)
  var ts = now()
  return transaction([
    "UPDATE items SET type = CASE type WHEN 'note' THEN 'todo' ELSE 'note' END, updated_at = " + ts
      + " WHERE id = " + nid,
    CHANGES,
    "INSERT INTO history (type, title, action, ts) "
      + "SELECT type, title, 'converted', " + ts + " FROM items WHERE id = " + nid
  ])
}

// Newest-first history rows. Capped to keep the table light.
function historySql() {
  return "SELECT id, type, title, action, ts FROM history "
    + "ORDER BY ts DESC, id DESC LIMIT 500"
}

function deleteHistorySql(id) {
  return "DELETE FROM history WHERE id = " + sqlId(id)
}

function clearHistorySql() {
  return "DELETE FROM history"
}

// A string rather than a .sql file: QML file:// and qs:// VFS URLs cannot be
// handed to the sqlite3 CLI, so init() must not need a filesystem path.
var SCHEMA = "CREATE TABLE IF NOT EXISTS items ("
  + "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
  + "  type TEXT NOT NULL,"
  + "  title TEXT NOT NULL,"
  + "  body TEXT,"
  + "  status INTEGER NOT NULL DEFAULT 0,"
  + "  created_at INTEGER NOT NULL,"
  + "  updated_at INTEGER NOT NULL"
  + ");"
  + "CREATE INDEX IF NOT EXISTS idx_items_sort ON items(status, updated_at DESC);"
  + "CREATE INDEX IF NOT EXISTS idx_items_type_status ON items(type, status);"
  + "CREATE TABLE IF NOT EXISTS history ("
  + "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
  + "  type TEXT NOT NULL,"
  + "  title TEXT NOT NULL,"
  + "  action TEXT NOT NULL,"
  + "  ts INTEGER NOT NULL"
  + ");"
  + "CREATE INDEX IF NOT EXISTS idx_history_ts ON history(ts DESC);"

// argv for a read or write via the sqlite3 CLI. `sql` is one statement or a
// transaction() array, one argument per statement. `json` enables -json output.
//
// `.timeout 5000` is a CLI dot-command (not SQL) that sets the busy timeout for
// the session: it makes sqlite wait up to 5s on a locked db instead of failing,
// and — unlike `PRAGMA busy_timeout=...` — it prints nothing, so it cannot
// corrupt the -json output.
function sqliteCommand(dbPath, sql, json) {
  var cmd = ["sqlite3"]
  if (json) cmd.push("-json")
  return cmd.concat(String(dbPath), ".timeout 5000", sql)
}

// argv for start-up: ensure the data dir exists, then apply the schema through
// sqliteCommand, so it waits on a locked db like every other write ("$@" is
// quoted, so the shell cannot mangle the SQL).
function initCommand(dataDir, dbPath) {
  return ["bash", "-c", 'mkdir -p -- "$0" && exec "$@"', String(dataDir)]
    .concat(sqliteCommand(dbPath, SCHEMA, false))
}

// Parse a `sqlite3 -json` result into an array of row objects. An empty result
// set prints nothing, so "" → []. Anything else that is not a JSON array throws.
function parseRows(text) {
  var t = String(text || "").trim()
  if (t === "") return []
  var rows
  try {
    rows = JSON.parse(t)
  } catch (e) {
    rows = null
  }
  if (!Array.isArray(rows)) throw new Error("unreadable sqlite3 output")
  return rows
}

// Parse countsSql() output into { unreadNotes, inProgressTodos, notes, todos }.
function parseCounts(text) {
  var rows = parseRows(text)
  var row = rows.length > 0 ? rows[0] : {}
  return {
    unreadNotes: Number(row.unreadNotes) || 0,
    inProgressTodos: Number(row.inProgressTodos) || 0,
    notes: Number(row.notes) || 0,
    todos: Number(row.todos) || 0
  }
}

// Parse addSql() output into the new item's id (-1 if absent). Writes run
// WITHOUT -json, so the output is a plain integer like "2\n".
function parseId(text) {
  var t = String(text || "").trim()
  var n = Number(t)
  return (t !== "" && isFinite(n)) ? n : -1
}

// Parse the CHANGES count a one-item write prints: false when no item had its id.
function parseFound(text) {
  return Number(String(text || "").trim()) > 0
}

// The first line sqlite3 printed on stderr, without the "Error in 3rd command
// line argument: " prefix that only locates the failing argument.
function errorText(stderr, exitCode) {
  var line = String(stderr || "").trim().split("\n")[0]
  line = line.replace(/^[A-Za-z ]*error( in \S+ command line argument)?: /i, "")
  return line !== "" ? line : "sqlite3 exited " + exitCode
}
