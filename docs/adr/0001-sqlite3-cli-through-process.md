# Talk to SQLite through the sqlite3 CLI

Omanotes reads and writes its database by running the `sqlite3` command-line tool through Quickshell's `Process`, one process per operation, with reads in `-json` mode (`data/Db.js` `sqliteCommand`, `data/Db.qml`). Quickshell ships no SQLite module, and `QtQuick.LocalStorage` keeps its databases under Qt's offline storage path, while Omanotes needs a known file under `$XDG_DATA_HOME/omarchy/` that scripts and the IPC can point at.

## Consequences

- SQL travels as text with no parameter binding (ADR-0002).
- Each write passes its statements as separate arguments between `BEGIN IMMEDIATE` and `COMMIT` (`transaction` in `data/Db.js`). The CLI stops at the first argument that fails and exits with the transaction open, so SQLite rolls it back and nothing is written. Inside a single argument the CLI keeps running the statements after a failure, which the audit of 2026-09-24 reproduced with a failing middle `INSERT`, so a write never joins its statements into one string.
- sqlite3 reports errors on stderr. No `Process` in `data/Db.qml` collects stderr yet, so a failed write only shows "sqlite3 exited N".
