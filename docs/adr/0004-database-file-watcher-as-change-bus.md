# Watch the database file to pick up changes

The database has several writers: the bar widget's `Db` (which also serves the IPC), the panel's `Db`, and anyone running `sqlite3` by hand. There is no channel between them, so each `Db` watches the database file with a `FileView` and reloads 250 ms after the file changes, plus 80 ms after each of its own writes (`data/Db.qml`). The file on disk is the single source of truth.

## Consequences

- This depends on the rollback journal (`journal_mode=delete`, the SQLite default and the mode of the live database). In WAL mode, writes land in `scratchpad.db-wal` and the main file only changes at checkpoint, so the watcher would miss them. Switching to WAL means replacing the watcher.
- One write triggers a reload in every `Db` instance, including the one that wrote it.
