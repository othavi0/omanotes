-- The schema of a database from before versioning, frozen: a shipped migration
-- never changes (ADR-0011). The tests write rows on it, then the binary migrates.
CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, title TEXT NOT NULL, body TEXT, status INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS idx_items_sort ON items(status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_items_type_status ON items(type, status);
CREATE TABLE IF NOT EXISTS history (id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, title TEXT NOT NULL, action TEXT NOT NULL, ts INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS idx_history_ts ON history(ts DESC);
