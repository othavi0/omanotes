namespace Omanotes.Db;

/// <summary>
/// The schema as ordered steps (ADR-0011): Steps[i] takes a file from
/// user_version i to i + 1. A shipped step never changes; a schema change
/// appends one. The text is the text data/Db.js MIGRATIONS ran, character for
/// character, so sqlite_master reads the same (test/bin-schema.test.mjs).
/// </summary>
internal static class Schema
{
    private static readonly Action<Conn>[][] Steps =
    [
        [
            db => db.Run($"CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, title TEXT NOT NULL, body TEXT, status INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)"),
            db => db.Run($"CREATE INDEX IF NOT EXISTS idx_items_sort ON items(status, updated_at DESC)"),
            db => db.Run($"CREATE INDEX IF NOT EXISTS idx_items_type_status ON items(type, status)"),
            db => db.Run($"CREATE TABLE IF NOT EXISTS history (id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, title TEXT NOT NULL, action TEXT NOT NULL, ts INTEGER NOT NULL)"),
            db => db.Run($"CREATE INDEX IF NOT EXISTS idx_history_ts ON history(ts DESC)"),
        ],
        [
            db => db.Run($"ALTER TABLE items ADD COLUMN search_title TEXT"),
            db => db.Run($"ALTER TABLE items ADD COLUMN search_body TEXT"),
            db => db.Run($"CREATE TABLE search_map (ch TEXT PRIMARY KEY, folded TEXT NOT NULL) WITHOUT ROWID"),
            LoadSearchMap,
            db => db.Run($"UPDATE items SET search_title = (WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < length(items.title)) SELECT group_concat(coalesce(search_map.folded, substr(items.title, n.i, 1)), '' ORDER BY n.i) FROM n LEFT JOIN search_map ON search_map.ch = substr(items.title, n.i, 1)), search_body = CASE WHEN items.body IS NULL THEN NULL ELSE (WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < length(items.body)) SELECT group_concat(coalesce(search_map.folded, substr(items.body, n.i, 1)), '' ORDER BY n.i) FROM n LEFT JOIN search_map ON search_map.ch = substr(items.body, n.i, 1)) END"),
            db => db.Run($"CREATE TRIGGER items_search_insert AFTER INSERT ON items WHEN NEW.search_title IS NULL BEGIN UPDATE items SET search_title = (WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < length(NEW.title)) SELECT group_concat(coalesce(search_map.folded, substr(NEW.title, n.i, 1)), '' ORDER BY n.i) FROM n LEFT JOIN search_map ON search_map.ch = substr(NEW.title, n.i, 1)), search_body = CASE WHEN NEW.body IS NULL THEN NULL ELSE (WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < length(NEW.body)) SELECT group_concat(coalesce(search_map.folded, substr(NEW.body, n.i, 1)), '' ORDER BY n.i) FROM n LEFT JOIN search_map ON search_map.ch = substr(NEW.body, n.i, 1)) END WHERE id = NEW.id; END"),
            db => db.Run($"CREATE TRIGGER items_search_update AFTER UPDATE OF title, body ON items WHEN NEW.search_title IS OLD.search_title AND NEW.search_body IS OLD.search_body BEGIN UPDATE items SET search_title = (WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < length(NEW.title)) SELECT group_concat(coalesce(search_map.folded, substr(NEW.title, n.i, 1)), '' ORDER BY n.i) FROM n LEFT JOIN search_map ON search_map.ch = substr(NEW.title, n.i, 1)), search_body = CASE WHEN NEW.body IS NULL THEN NULL ELSE (WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < length(NEW.body)) SELECT group_concat(coalesce(search_map.folded, substr(NEW.body, n.i, 1)), '' ORDER BY n.i) FROM n LEFT JOIN search_map ON search_map.ch = substr(NEW.body, n.i, 1)) END WHERE id = NEW.id; END"),
        ],
        [
            db => db.Run($"ALTER TABLE items ADD COLUMN position INTEGER NOT NULL DEFAULT 0"),
            db => db.Run($"UPDATE items SET position = shown.position FROM (SELECT id, ROW_NUMBER() OVER (PARTITION BY status ORDER BY updated_at DESC, id DESC) AS position FROM items) AS shown WHERE items.id = shown.id"),
            db => db.Run($"DROP INDEX IF EXISTS idx_items_sort"),
            db => db.Run($"CREATE INDEX idx_items_order ON items(status, position)"),
        ],
        [
            db => db.Run($"CREATE TABLE alarms (id INTEGER PRIMARY KEY AUTOINCREMENT, hour INTEGER NOT NULL CHECK (hour BETWEEN 0 AND 23), minute INTEGER NOT NULL CHECK (minute BETWEEN 0 AND 59), label TEXT NOT NULL DEFAULT '' CHECK (length(label) <= 40), days INTEGER NOT NULL DEFAULT 0 CHECK (days BETWEEN 0 AND 127), enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)), snooze_minutes INTEGER NOT NULL DEFAULT 9 CHECK (snooze_minutes BETWEEN 1 AND 180), ring_minutes INTEGER NOT NULL DEFAULT 5 CHECK (ring_minutes BETWEEN 1 AND 60), snoozed_until_ms INTEGER NOT NULL DEFAULT 0, last_fired_at_ms INTEGER NOT NULL DEFAULT 0, armed_at_ms INTEGER NOT NULL DEFAULT (strftime('%s', 'now') * 1000), auto_snoozes INTEGER NOT NULL DEFAULT 0 CHECK (auto_snoozes BETWEEN 0 AND 99))"),
        ],
        [
            db => db.Run($"CREATE TABLE settings (id INTEGER PRIMARY KEY CHECK (id = 1), sound_on INTEGER NOT NULL DEFAULT 1 CHECK (sound_on IN (0, 1)), sound TEXT NOT NULL DEFAULT 'alarm-clock-elapsed', sound_file TEXT NOT NULL DEFAULT '', volume INTEGER NOT NULL DEFAULT 100 CHECK (volume BETWEEN 0 AND 100), snooze_minutes INTEGER NOT NULL DEFAULT 9 CHECK (snooze_minutes BETWEEN 1 AND 180), ring_minutes INTEGER NOT NULL DEFAULT 5 CHECK (ring_minutes BETWEEN 1 AND 60), history_days INTEGER NOT NULL DEFAULT 0 CHECK (history_days IN (0, 30, 90)), check_updates INTEGER NOT NULL DEFAULT 1 CHECK (check_updates IN (0, 1)))"),
            db => db.Run($"INSERT INTO settings (id) VALUES (1)"),
        ],
    ];

    public static int Current => Steps.Length;

    /// <summary>
    /// Brings the file to Current. The version is read again under BEGIN
    /// IMMEDIATE, so of two processes that both saw an old version only the
    /// first migrates: the second waits on the lock, reads Current and stops.
    /// This replaces the TEMP table, the CHECK trick and the stderr match of
    /// Db.js. A file above Current, written by a newer Omanotes, is used as it
    /// is. Returns the version the file had, for the log.
    /// </summary>
    public static int Migrate(Conn db)
    {
        int before = Version(db);
        if (before >= Current)
        {
            return before;
        }

        using Conn.Tx tx = db.Immediate();
        before = Version(db);
        for (int v = before; v < Current; v++)
        {
            foreach (Action<Conn> statement in Steps[v])
            {
                statement(db);
            }
        }

        if (before < Current)
        {
            db.SetUserVersion(Current);
        }

        tx.Commit();
        return before;
    }

    public static int Version(Conn db) => (int)db.Scalar($"PRAGMA user_version");

    /// <summary>The fold table, one bound insert per row, from the same file Fold.Text reads.</summary>
    private static void LoadSearchMap(Conn db)
    {
        foreach ((char unit, string folded) in Fold.Rows)
        {
            _ = db.Run($"INSERT INTO search_map VALUES (?1, ?2)", Value.Of(new string(unit, 1)), Value.Of(folded));
        }
    }
}
