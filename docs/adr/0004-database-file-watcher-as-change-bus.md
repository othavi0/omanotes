# Watch the database file to pick up changes

The database has several writers: the `Db` of each bar widget (one per monitor, which also serves the IPC and is shared with that widget's panel) and anyone running `sqlite3` by hand. There is no channel between them, so each `Db` watches the database file with a `FileView`. A change to the file and the end of one of its own writes restart the same 80 ms timer, and the `Db` reloads when it fires (`data/Db.qml`). The file on disk is the single source of truth.

## Consequences

- This depends on the rollback journal (`journal_mode=delete`, the SQLite default and the mode of the live database). In WAL mode, writes land in `scratchpad.db-wal` and the main file only changes at checkpoint, so the watcher would miss them. Switching to WAL means replacing the watcher.
- One write reloads each `Db` once, including the one that wrote it. With several monitors, that is one reload per monitor.
- The panel's filter and search narrow `items`. The IPC reads `allItems`, which a reload always fetches unfiltered, so the panel cannot hide an item from a script.
- The IPC writes inside `db.fromScript`, so a script's write reloads the panel but emits none of the signals the panel answers as its user's action (a selection change, a toast). Adding, toggling and clearing history from a script do not move the selection or commit an edit the user has not left (ADR-0007). Removing the item open in the editor still does both, because the reload drops the selected row. Issue #10 covers that case.
