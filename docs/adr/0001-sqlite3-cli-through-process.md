# Talk to SQLite through the sqlite3 CLI

Omanotes reads and writes its database by running the `sqlite3` command-line tool through Quickshell's `Process`, one process per operation, with reads in `-json` mode (`data/Db.js` `sqliteCommand`, `data/Db.qml`). Quickshell ships no SQLite module, and `QtQuick.LocalStorage` keeps its databases under Qt's offline storage path, while Omanotes needs a known file under `$XDG_DATA_HOME/omarchy/` that scripts and the IPC can point at.

## Consequences

- SQL travels as text with no parameter binding (ADR-0002).
- Each write is one SQL string wrapped in `BEGIN; ... COMMIT;`. When a statement in the middle fails, the CLI still runs the ones after it, so the batch is not atomic. The audit of 2026-09-24 reproduced this with a failing middle `INSERT`. Running each statement as its own argument stops at the failure.
- sqlite3 reports errors on stderr. No `Process` in `data/Db.qml` collects stderr yet, so a failed write only shows "sqlite3 exited N".
