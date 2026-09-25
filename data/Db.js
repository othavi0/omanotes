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

// The copy of a title or body that search matches against: lower case, without
// the accents of the Combining Diacritical Marks block. It works one UTF-16
// unit at a time and leaves surrogates as they are, because the migration
// applies the same map one character at a time in SQL (foldedSql), and both
// must give every item the same copy.
function searchChar(c) {
  if (c >= "\ud800" && c <= "\udfff") return c
  return c.toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "").normalize("NFC")
}

function searchText(text) {
  return String(text).replace(/[\s\S]/g, searchChar)
}

// Unified list. filterType is "all"|"note"|"todo";
// query is an optional substring match on title or body that ignores case and
// accents (searchText).
// Sort order: pending (unread/in-progress, status 0) always on top, then
// recency — `status ASC, updated_at DESC`.
function listSql(filterType, query) {
  var where = []
  var ft = String(filterType || "all")
  if (ft !== "all") {
    if (ft !== "note" && ft !== "todo") ft = "all"
    else where.push("type = " + q(ft))
  }
  var needle = searchText(String(query || "").trim())
  if (needle !== "") {
    var pattern = q("%" + likeEscape(needle) + "%")
    where.push("(search_title LIKE " + pattern + " ESCAPE '\\' OR search_body LIKE " + pattern + " ESCAPE '\\')")
  }
  var sql = "SELECT id, type, title, body, status, created_at, updated_at FROM items"
  if (where.length > 0) sql += " WHERE " + where.join(" AND ")
  sql += " ORDER BY status ASC, updated_at DESC, id DESC"
  return sql
}

// Pending counts for the bar tooltip and the panel header: unread notes /
// in-progress todos, unfiltered totals per type for the filter segment, and
// every history entry, including those past historySql()'s limit.
function countsSql() {
  return "SELECT "
    + "(SELECT COUNT(*) FROM items WHERE type = 'note' AND status = 0) AS unreadNotes, "
    + "(SELECT COUNT(*) FROM items WHERE type = 'todo' AND status = 0) AS inProgressTodos, "
    + "(SELECT COUNT(*) FROM items WHERE type = 'note') AS notes, "
    + "(SELECT COUNT(*) FROM items WHERE type = 'todo') AS todos, "
    + "(SELECT COUNT(*) FROM history) AS history"
}

// One argument per statement: the CLI stops at the first failing argument and
// the open transaction rolls back, while statements joined in one argument keep
// running past a failure (ADR-0001). IMMEDIATE takes the write lock up front.
function transaction(statements) {
  return ["BEGIN IMMEDIATE"].concat(statements, ["COMMIT"])
}

function bodySql(body) {
  return (body === null || body === undefined || body === "") ? "NULL" : q(body)
}

function searchBodySql(body) {
  return bodySql(body) === "NULL" ? "NULL" : q(searchText(body))
}

// Insert a new item (status 0) + "added" history row, and return its id.
// The `SELECT last_insert_rowid()` sits between the two INSERTs so it captures
// the items row (a later history INSERT would otherwise move last_insert_rowid).
function addSql(type, title, body) {
  var t = (type === "todo") ? "todo" : "note"
  var ts = now()
  var b = bodySql(body)
  return transaction([
    "INSERT INTO items (type, title, body, search_title, search_body, status, created_at, updated_at) VALUES ("
      + q(t) + ", " + q(title) + ", " + b + ", " + q(searchText(title)) + ", " + searchBodySql(body)
      + ", 0, " + ts + ", " + ts + ")",
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
  var ts = now()
  return transaction([
    "UPDATE items SET title = " + q(title) + ", body = " + bodySql(body)
      + ", search_title = " + q(searchText(title)) + ", search_body = " + searchBodySql(body)
      + ", updated_at = " + ts + " WHERE id = " + nid,
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

// The newest 500 history rows, for the History tab. The table keeps growing;
// countsSql() counts all of it.
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

// searchText(column) in SQL: each character through search_map, joined back
// in order.
function foldedSql(column) {
  var ch = "substr(" + column + ", n.i, 1)"
  return "(WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < length(" + column + "))"
    + " SELECT group_concat(coalesce(search_map.folded, " + ch + "), '' ORDER BY n.i)"
    + " FROM n LEFT JOIN search_map ON search_map.ch = " + ch + ")"
}

function copiesSql(row) {
  return "search_title = " + foldedSql(row + ".title") + ", search_body = CASE WHEN " + row
    + ".body IS NULL THEN NULL ELSE " + foldedSql(row + ".body") + " END"
}

// Adds the search copy and fills it for the items already there. search_map
// holds every character searchChar changes; SQLite's lower() only knows ASCII,
// so it covers that too. Building the map takes tens of milliseconds, so it is
// built only when a database needs this step.
// The triggers fold the rows written with sqlite3, which leave the copy empty
// on insert or as it was on update. addSql and updateSql write it themselves,
// but an edit that changes only case or accents leaves the copy equal to the
// old one, so the update trigger folds it again (ADR-0012).
function searchCopyMigration() {
  var rows = []
  for (var u = 0; u < 0x10000; u++) {
    var c = String.fromCharCode(u)
    var s = searchChar(c)
    if (s !== c) rows.push("(" + q(c) + ", " + q(s) + ")")
  }
  return [
    "ALTER TABLE items ADD COLUMN search_title TEXT",
    "ALTER TABLE items ADD COLUMN search_body TEXT",
    "CREATE TABLE search_map (ch TEXT PRIMARY KEY, folded TEXT NOT NULL) WITHOUT ROWID",
    "INSERT INTO search_map VALUES " + rows.join(", "),
    "UPDATE items SET " + copiesSql("items"),
    "CREATE TRIGGER items_search_insert AFTER INSERT ON items WHEN NEW.search_title IS NULL"
      + " BEGIN UPDATE items SET " + copiesSql("NEW") + " WHERE id = NEW.id; END",
    "CREATE TRIGGER items_search_update AFTER UPDATE OF title, body ON items"
      + " WHEN NEW.search_title IS OLD.search_title AND NEW.search_body IS OLD.search_body"
      + " BEGIN UPDATE items SET " + copiesSql("NEW") + " WHERE id = NEW.id; END"
  ]
}

// The schema, as the steps that build it. Entry i takes a database from
// user_version i to i + 1: its statements, one per element (ADR-0001), or a
// function that returns them. A shipped entry never changes: a schema change
// appends one (ADR-0011). The first entry keeps IF NOT EXISTS because
// databases made before versioning have its tables at version 0.
var MIGRATIONS = [
  [
    "CREATE TABLE IF NOT EXISTS items ("
      + "id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, title TEXT NOT NULL, body TEXT,"
      + " status INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)",
    "CREATE INDEX IF NOT EXISTS idx_items_sort ON items(status, updated_at DESC)",
    "CREATE INDEX IF NOT EXISTS idx_items_type_status ON items(type, status)",
    "CREATE TABLE IF NOT EXISTS history ("
      + "id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, title TEXT NOT NULL,"
      + " action TEXT NOT NULL, ts INTEGER NOT NULL)",
    "CREATE INDEX IF NOT EXISTS idx_history_ts ON history(ts DESC)"
  ],
  searchCopyMigration
]

var VERSION_CHANGED = "version_changed"

// The migrations above `version`, in one transaction that ends at the current
// version, or [] when there are none. Every widget starts its own Db, so
// another start-up can migrate between the version read and this write: the
// first statements then fail with VERSION_CHANGED and nothing is written.
function migrateSql(version) {
  var steps = []
  for (var v = version; v < MIGRATIONS.length; v++) {
    var entry = MIGRATIONS[v]
    steps = steps.concat(typeof entry === "function" ? entry() : entry)
  }
  if (steps.length === 0) return []
  return transaction([
    "CREATE TEMP TABLE migrating_from (version INTEGER CONSTRAINT " + VERSION_CHANGED
      + " CHECK (version = " + version + "))",
    "INSERT INTO migrating_from SELECT user_version FROM pragma_user_version"
  ].concat(steps, ["PRAGMA user_version = " + MIGRATIONS.length]))
}

function migrationRaced(stderr) {
  return errorText(stderr, 1) === "CHECK constraint failed: " + VERSION_CHANGED
}

// argv for a read or write via the sqlite3 CLI. `sql` is one statement or a
// transaction() array, one argument per statement. `json` enables -json output.
//
// `.timeout 5000` is a CLI dot-command (not SQL) that sets the busy timeout for
// the session: it makes sqlite wait up to 5s on a locked db instead of failing,
// and — unlike `PRAGMA busy_timeout=...` — it prints nothing, so it cannot
// corrupt the -json output.
//
// `-init /dev/null` skips the user's sqliterc, which the CLI reads even when not
// interactive: a `.headers on` there turns a write's "1" into "changes()\n1".
function sqliteCommand(dbPath, sql, json) {
  var cmd = ["sqlite3", "-init", "/dev/null"]
  if (json) cmd.push("-json")
  return cmd.concat(String(dbPath), ".timeout 5000", sql)
}

// argv for start-up: ensure the data dir exists, then read the schema version
// through sqliteCommand, so it waits on a locked db like every other command
// ("$@" is quoted, so the shell cannot mangle the SQL).
function initCommand(dataDir, dbPath) {
  return ["bash", "-c", 'mkdir -p -- "$0" && exec "$@"', String(dataDir)]
    .concat(sqliteCommand(dbPath, "PRAGMA user_version", false))
}

function parseVersion(text) {
  var t = String(text || "").trim()
  if (!/^\d+$/.test(t)) throw new Error("unreadable sqlite3 output")
  return Number(t)
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

// Parse countsSql() output into { unreadNotes, inProgressTodos, notes, todos, history }.
function parseCounts(text) {
  var rows = parseRows(text)
  var row = rows.length > 0 ? rows[0] : {}
  return {
    unreadNotes: Number(row.unreadNotes) || 0,
    inProgressTodos: Number(row.inProgressTodos) || 0,
    notes: Number(row.notes) || 0,
    todos: Number(row.todos) || 0,
    history: Number(row.history) || 0
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
