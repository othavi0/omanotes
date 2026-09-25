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
// Order: status 0 (unread notes, pending todos) first, then each block by
// position (ADR-0014). Every filter reads the same order.
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
  sql += " ORDER BY status ASC, position ASC, id DESC"
  return sql
}

// The position above every item of the block with `status`.
function topOfBlockSql(status) {
  return "(SELECT COALESCE(MIN(position), 1) - 1 FROM items WHERE status = " + status + ")"
}

// Counts for the bar tooltip and the panel header: unread notes and pending
// todos, unfiltered totals per type for the filter segment, and
// every history entry, including those past historySql()'s limit.
function countsSql() {
  return "SELECT "
    + "(SELECT COUNT(*) FROM items WHERE type = 'note' AND status = 0) AS unreadNotes, "
    + "(SELECT COUNT(*) FROM items WHERE type = 'todo' AND status = 0) AS pendingTodos, "
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

// Insert a new item (status 0, top of its block) + "added" history row, and
// return its id. The `SELECT last_insert_rowid()` sits between the two INSERTs
// so it captures the items row (a later history INSERT would otherwise move
// last_insert_rowid).
function addSql(type, title, body) {
  var t = (type === "todo") ? "todo" : "note"
  var ts = now()
  var b = bodySql(body)
  return transaction([
    "INSERT INTO items (type, title, body, search_title, search_body, status, position, created_at, updated_at) VALUES ("
      + q(t) + ", " + q(title) + ", " + b + ", " + q(searchText(title)) + ", " + searchBodySql(body)
      + ", 0, " + topOfBlockSql(0) + ", " + ts + ", " + ts + ")",
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

// Set an item's status (0 or 1), moving it to the top of its new block, +
// record "completed"/"reopened" history.
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
    "UPDATE items SET status = " + s
      + ", position = CASE status WHEN " + s + " THEN position ELSE " + topOfBlockSql(s) + " END"
      + ", updated_at = CASE status WHEN " + s + " THEN updated_at ELSE " + ts + " END WHERE id = " + nid,
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

// Put item `id` just before item `anchorId` of the same block, or just after
// it when `after`, and number that block 1, 2, 3… in the new order. The item
// takes the anchor's place in the list order (position, then id DESC), with
// one more key to fall before or after it. Nothing is written, and CHANGES
// prints 0, when either id is missing, they are the same item or the two sit
// in different blocks. A move is not an action, so it leaves history and
// updated_at alone.
function moveSql(id, anchorId, after) {
  var nid = sqlId(id)
  var aid = sqlId(anchorId)
  var key = function(moved, other) { return "CASE i.id WHEN " + nid + " THEN " + moved + " ELSE " + other + " END" }
  return transaction([
    "UPDATE items SET position = moved.position FROM (SELECT i.id, ROW_NUMBER() OVER (ORDER BY "
      + key("a.position", "i.position") + ", " + key("a.id", "i.id") + " DESC, " + key(after ? 2 : 0, 1)
      + ") AS position FROM items i JOIN items a ON a.id = " + aid + " AND a.status = i.status"
      + " JOIN items m ON m.id = " + nid + " AND m.status = a.status AND m.id <> a.id) AS moved"
      + " WHERE items.id = moved.id",
    CHANGES
  ])
}

// `rows` with the row `id` moved as moveSql moves it, so the list shows the
// drop before the reload confirms it. The same rows when either is missing.
function movedRows(rows, id, anchorId, after) {
  var list = rows.slice()
  var from = -1
  for (var i = 0; i < list.length; ++i) if (Number(list[i].id) === Number(id)) from = i
  if (from < 0) return list
  var row = list.splice(from, 1)[0]
  for (var j = 0; j < list.length; ++j) {
    if (Number(list[j].id) !== Number(anchorId)) continue
    list.splice(after ? j + 1 : j, 0, row)
    return list
  }
  return rows.slice()
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

// A whole number in [min, max], for interpolation into SQL text (ADR-0002),
// as sqlId is for ids.
function sqlInt(value, min, max) {
  var n = Number(value)
  if (typeof value === "boolean" || !/^-?\d+$/.test(String(value)) || n < min || n > max) {
    throw new Error("invalid value: " + value)
  }
  return n
}

// A list of Date.getDay() indices <-> the days bitmask, bit 0 for Sunday.
function daysMask(days) {
  var mask = 0
  var list = days || []
  for (var i = 0; i < list.length; i++) {
    var d = Number(list[i])
    if (d >= 0 && d <= 6 && d === Math.round(d)) mask |= 1 << d
  }
  return mask
}

function maskDays(mask) {
  var days = []
  for (var d = 0; d <= 6; d++) if ((Number(mask) >> d) & 1) days.push(d)
  return days
}

var ALARM_COLUMNS = "id, hour, minute, label, days, enabled, snooze_minutes, ring_minutes,"
  + " snoozed_until_ms, last_fired_at_ms, armed_at_ms, auto_snoozes"

function alarmsSql() {
  return "SELECT " + ALARM_COLUMNS + " FROM alarms ORDER BY hour, minute, id"
}

// The mutable columns of an alarm as [column, value] pairs, checked before
// any SQL exists. The CHECK constraints refuse the same ranges again.
function alarmValues(record) {
  var ms = Number.MAX_SAFE_INTEGER
  return [
    ["hour", sqlInt(record.hour, 0, 23)],
    ["minute", sqlInt(record.minute, 0, 59)],
    ["label", q(record.label || "")],
    ["days", daysMask(record.days)],
    ["enabled", record.enabled ? 1 : 0],
    ["snooze_minutes", sqlInt(record.snoozeMinutes, 1, 180)],
    ["ring_minutes", sqlInt(record.ringMinutes, 1, 60)],
    ["snoozed_until_ms", sqlInt(record.snoozedUntil, 0, ms)],
    ["last_fired_at_ms", sqlInt(record.lastFiredAt, 0, ms)],
    ["armed_at_ms", sqlInt(record.armedAt, 0, ms)],
    ["auto_snoozes", sqlInt(record.autoSnoozes, 0, 99)]
  ]
}

// Insert a new alarm and print its id. No history row: alarms stay out of
// History.
function insertAlarmSql(record) {
  var values = alarmValues(record)
  return transaction([
    "INSERT INTO alarms (" + values.map(function(v) { return v[0] }).join(", ") + ") VALUES ("
      + values.map(function(v) { return v[1] }).join(", ") + ")",
    "SELECT last_insert_rowid() AS id"
  ])
}

// Write every mutable column of one alarm, then CHANGES. The record is
// absolute, so sending it twice leaves the same row, which is what lets the
// alarm store retry a failed write.
function saveAlarmSql(record) {
  var nid = sqlId(record.id)
  var set = alarmValues(record).map(function(v) { return v[0] + " = " + v[1] })
  return transaction(["UPDATE alarms SET " + set.join(", ") + " WHERE id = " + nid, CHANGES])
}

function deleteAlarmSql(id) {
  return transaction(["DELETE FROM alarms WHERE id = " + sqlId(id), CHANGES])
}

function clampedInt(value, min, max, fallback) {
  var n = Math.round(Number(value))
  if (value === null || value === "" || !isFinite(n)) return fallback
  return Math.max(min, Math.min(max, n))
}

// sqlite3 -json rows of alarmsSql -> Alarm records: numbers, a days list and
// a boolean, with camelCase names. SQLite keeps a fraction written to an
// INTEGER column as REAL, so a hand edit can leave 6.4 in `hour`.
function parseAlarms(text) {
  var ms = Number.MAX_SAFE_INTEGER
  return parseRows(text).map(function(row) {
    return {
      id: Number(row.id),
      hour: clampedInt(row.hour, 0, 23, null),
      minute: clampedInt(row.minute, 0, 59, null),
      label: String(row.label || ""),
      days: maskDays(row.days),
      enabled: Number(row.enabled) === 1,
      snoozeMinutes: clampedInt(row.snooze_minutes, 1, 180, 9),
      ringMinutes: clampedInt(row.ring_minutes, 1, 60, 5),
      snoozedUntil: clampedInt(row.snoozed_until_ms, 0, ms, 0),
      lastFiredAt: clampedInt(row.last_fired_at_ms, 0, ms, 0),
      armedAt: clampedInt(row.armed_at_ms, 0, ms, 0),
      autoSnoozes: clampedInt(row.auto_snoozes, 0, 99, 0)
    }
  }).filter(function(alarm) {
    return alarm.id > 0 && alarm.hour !== null && alarm.minute !== null
  })
}

// The rows with each pending record laid over its row. A pending null drops
// the row, and a pending record whose row is gone is not brought back. The
// order is alarmsSql's order.
function mergeAlarms(rows, pending) {
  var out = []
  for (var i = 0; i < rows.length; i++) {
    var entry = pending ? pending[rows[i].id] : undefined
    if (entry === undefined) out.push(rows[i])
    else if (entry.record !== null) out.push(entry.record)
  }
  return out
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
  searchCopyMigration,
  // Numbers each block in the order the list showed before (ADR-0014).
  [
    "ALTER TABLE items ADD COLUMN position INTEGER NOT NULL DEFAULT 0",
    "UPDATE items SET position = shown.position FROM (SELECT id, ROW_NUMBER() OVER"
      + " (PARTITION BY status ORDER BY updated_at DESC, id DESC) AS position FROM items) AS shown"
      + " WHERE items.id = shown.id",
    "DROP INDEX IF EXISTS idx_items_sort",
    "CREATE INDEX idx_items_order ON items(status, position)"
  ],
  // Alarms (ADR-0015). Instants are epoch ms (the _ms columns), unlike the
  // seconds of items. days is a bitmask of Date.getDay() indices, bit 0 for
  // Sunday, and 0 rings once. armed_at_ms defaults to the insert time, so a
  // row written with sqlite3 does not ring an occurrence from before it existed.
  [
    "CREATE TABLE alarms ("
      + "id INTEGER PRIMARY KEY AUTOINCREMENT,"
      + " hour INTEGER NOT NULL CHECK (hour BETWEEN 0 AND 23),"
      + " minute INTEGER NOT NULL CHECK (minute BETWEEN 0 AND 59),"
      + " label TEXT NOT NULL DEFAULT '' CHECK (length(label) <= 40),"
      + " days INTEGER NOT NULL DEFAULT 0 CHECK (days BETWEEN 0 AND 127),"
      + " enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),"
      + " snooze_minutes INTEGER NOT NULL DEFAULT 9 CHECK (snooze_minutes BETWEEN 1 AND 180),"
      + " ring_minutes INTEGER NOT NULL DEFAULT 5 CHECK (ring_minutes BETWEEN 1 AND 60),"
      + " snoozed_until_ms INTEGER NOT NULL DEFAULT 0,"
      + " last_fired_at_ms INTEGER NOT NULL DEFAULT 0,"
      + " armed_at_ms INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000),"
      + " auto_snoozes INTEGER NOT NULL DEFAULT 0 CHECK (auto_snoozes BETWEEN 0 AND 99))"
  ]
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

// Parse countsSql() output into { unreadNotes, pendingTodos, notes, todos, history }.
function parseCounts(text) {
  var rows = parseRows(text)
  var row = rows.length > 0 ? rows[0] : {}
  return {
    unreadNotes: Number(row.unreadNotes) || 0,
    pendingTodos: Number(row.pendingTodos) || 0,
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
