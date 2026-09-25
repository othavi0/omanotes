# Talk to SQLite through the sqlite3 CLI

Omanotes reads and writes its database by running the `sqlite3` command-line tool through Quickshell's `Process`, one process per operation, with reads in `-json` mode (`data/Db.js` `sqliteCommand`, `data/DbCore.qml`). Quickshell ships no SQLite module, and `QtQuick.LocalStorage` keeps its databases under Qt's offline storage path, while Omanotes needs a known file under `$XDG_DATA_HOME/omarchy/` that scripts and the IPC can point at.

## Consequences

- SQL travels as text with no parameter binding (ADR-0002).
- Each write passes its statements as separate arguments between `BEGIN IMMEDIATE` and `COMMIT` (`transaction` in `data/Db.js`). The CLI stops at the first argument that fails and exits with the transaction open, so SQLite rolls it back and nothing is written. Inside a single argument the CLI keeps running the statements after a failure, which the audit of 2026-09-24 reproduced with a failing middle `INSERT`, so a write never joins its statements into one string.
- sqlite3 reports errors on stderr, so every `Process` in `data/DbCore.qml`, `data/ItemsDb.qml` and `data/AlarmsDb.qml` collects stderr, and `errorText` in `data/Db.js` turns it into the message the toast and the journal show.
- The CLI reads the user's sqliterc even when it is not interactive, and a setting there such as `.headers on` changes what every command prints. `sqliteCommand` passes `-init /dev/null`, so Omanotes parses the same output on every machine.
- A write that changes no row still exits 0. The writes that target one item print `SELECT changes()`, and `data/ItemsDb.qml` reports "item not found" when it reads 0.
