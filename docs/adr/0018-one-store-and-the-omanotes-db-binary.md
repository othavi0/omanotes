# Read and write the database through one Store and the omanotes-db binary

Omanotes used to run the `sqlite3` CLI once per read and once per write (ADR-0001), with SQL built as text in `data/Db.js` (ADR-0002). Every bar widget had its own `Db`, so a reload of a shell with three monitors and the service started 17 processes, and the start-up 21. Each `Db` kept its own copy of the items and the history. A write carried the title and the body in argv, twice counting the search copy, and an argument over 128 KiB kept the process from starting without a word: a body of about 65 000 ASCII characters or more was lost (issue #55). Two start-ups raced to migrate, and a TEMP table and the words on stderr told the loser to read the version again.

The data layer now talks to `bin/omanotes-db.<machine>`, a C# NativeAOT binary built from `db/` that lives for one request. It uses the system's `libsqlite3.so.0`, holds every statement and migration, and has no clock and reads no environment variable. One request is one spawn:

- argv is `[bin, protocol, "run", dbPath]`. No user text travels in argv.
- stdin is one JSON object of up to 1 MiB: the writes in order, each `{ id, by, op, at, args }`, and a `sync` that asks for the snapshot after them. The binary gives up with `timeout` when stdin stays open 2 s without a byte.
- stdout carries the whole answer, only on exit 0: the result of each write, then the snapshot or `syncErr`. On exit 1, 64 or 70 the last line of stderr is `{"err","detail"}`. Any other exit or a signal is a crash.
- The snapshot is everything a reload reads, in one read transaction: the settings row with the file size, the counts, every item, the newest 500 history entries, the alarms, and the ids each search matched. Each cell comes in the storage class `sqlite3 -json` printed, and an infinite REAL as `9e999`.

`data/Store.qml` is a singleton (`pragma Singleton`, listed in `data/qmldir`), so the three bar widgets and the service share one. It keeps the write queue, the snapshot, the watcher and two lanes (`data/Lane.qml`), one for writes and one for reads, so a write that waits on a lock held outside never holds up the list. A request carries every write queued so far and the sync, so a write and the reload it causes are one spawn. `data/ItemsDb.qml` and `data/AlarmsDb.qml` are views over the Store with the API they had: the filter and search of a panel, the settings overlay, the alarm overlay and its retry, and the signals. `data/Db.js` keeps what has no SQL: `SETTINGS`, the coercion of raw cells (`parseSettings`, `parseAlarms`, `parseCounts`, `clampedInt`), the overlays, the request with `wellFormed`, `reply`, and `ERROR_TEXT` with `errorText`. `data/DbCore.qml` is gone.

## Considered options

- The CLI as it was. The spawn count grows with the monitors, and the #55 loss is in the transport.
- A resident helper process. It costs 6 to 8 MB per instance for as long as the shell runs, against 0 before, and needs a way to die with the shell.
- C# inside the shell's process. A crash in it takes the whole omarchy-shell down, and a loaded `.so` never unloads.
- One view per monitor with a spawn of its own. It makes M + 1 spawns per reload and M copies of the rows, where the singleton makes one of each.
- Coercion in C#. It repeats the rules of `Number()` and `Math.round` in a second language, and the tests would need the old JS as an oracle for good. The snapshot sends raw cells instead, and the same JS coerces them.

## Consequences

- Requests per event, measured with three monitors and the service: start-up 1 (21 before), a write from outside 1 (17), a write through the IPC 2 (18): the write with its snapshot, then the watcher's read, which the binary answers `unchanged`. A type filter costs no spawn, and a search costs one.
- The snapshot carries a stamp, the file change counter of the header, which every commit moves in rollback-journal mode. A request sends the stamp it shows as `since`, and the binary answers `unchanged` when the file did not move, so the echo of a write never rebuilds a list (ADR-0004). In WAL the stamp is -1 and no read is skipped. A read that ran before a snapshot already shown and reads an older stamp is dropped. A request sent after the snapshot shown was applied is shown whatever its stamp, since a file replaced by hand, such as a restored backup, starts its counter again.
- A view drops what it laid over the rows for a write once `Store.covered`, the id of the last write a shown snapshot includes, reaches that write. For a read, that is the last write whose result had landed when the read was sent. That keeps the rule of ADR-0015 and ADR-0016: a read that ran before a write ended never drops the write's overlay.
- The binary checks who sends each write: `alarm.*` only from the service and `settings.set` only from a widget, so ADR-0015 and ADR-0016 hold in the binary, not only in the callers.
- The wire carries codes. The words stay in `data/Db.js`: "item not found" and "database is locked" as before, and SQLite's own words for `io`, `refused`, `corrupt` and `sqlite`. The Store adds `crash` and `no_binary`.
- `wellFormed` turns a lone surrogate into U+FFFD before the request is written, as the CLI's argv did. The QML engine would send it raw, and the binary refuses an escaped one.
- The Store reads the machine from `/proc/sys/kernel/arch`, which the kernel documents as the output of `uname -m`, and costs no spawn. A machine with no binary, or a kernel without that file, gets `no_binary` with the path it tried. The kernel version that added the file was not checked.
- A start that fails (a missing file, no exec bit) emits no `exited`. The Lane reports it as `no_binary`, the writes in it fail in their panel, and the queue moves on. A failed read or request asks again from 500 ms up to every 30 s.
- The Lane writes the request in `onStarted`, closes stdin, and starts the binary with an empty environment: a `DOTNET_*` variable of the session changes the runtime's memory limits.
- The watcher `FileView` has `preload: false`. Preloaded, every copy of it held the whole database file in memory. It is reloaded once, when the first snapshot lands, because a watch set while the folder did not exist watches nothing.
- The Store does nothing while no view is attached: no watcher, no spawn. Like every component of the plugin, it keeps its code and state across a plugin reload until the shell restarts (ADR-0017). The first view that attaches after a time with none makes it read the file again, since nothing watched the file meanwhile.
- An alarm write the schema refuses, such as a label over 40 characters, stays laid over its row and is not retried. The CLI version retried it forever.
- A request is at most 1 MiB. The Store sends what fits and refuses alone a write that cannot fit, with "text too large to save", and the editor gets the text back. A body of 70 000 characters, lost before, is saved.
- Protocol: argv[1] is `PROTOCOL` from `data/Db.js`, and the binary answers every protocol from its `Min` to its `Current` (`db/Wire.cs`). A release that raises `Current` keeps `Min = Current - 1`, because the old QML runs against the new binary between an update and the restart (ADR-0017). Outside that range the toast says "Omanotes was updated. Run omarchy restart shell to finish".
- `bin/` is committed, and only `tools/build.sh` writes it. A change to `db/` needs a rebuild and the new binaries in the same commit, or `npm test` fails in `tools/verify-bin.sh --check`.
- Known limit: the binary holds its whole answer before writing it, so its peak memory grows with the snapshot. One spawn on 1 000 items with bodies of 200 characters peaked at 7.5 to 7.8 MB, under the 8 MB gate. With bodies of 1 200 characters it peaked at 8.8 to 9.0 MB.

## Gates

Each gate is a test that failed with its defect planted and passes without it.

- One Store for three widgets and the service (`test/startup.sh`). It failed when the service imported `data/` through a second path.
- One request per reload, whatever the number of monitors: a write from outside, and every panel asking at once (`test/startup.sh`). It failed when `Store.reload` stopped batching the calls of one tick.
- No `omanotes-db` process alive after the requests (`test/startup.sh`). It failed when the Lane closed stdin 1.5 s late.
- A peak of 8 MB or less per spawn on 1 000 items of 200 characters, for a reload and for a write with its snapshot (`test/bin-rss.test.mjs`). It failed with bodies of 1 200 characters.
- A body of 70 000 characters is saved (#55), and one over the cap is refused and given back (`test/startup.sh`). It failed with a cap of 64 KiB.
- A start that fails shows its error in the panel and the queue moves on (`test/startup.sh`). It failed when the Lane ignored a start that failed.
- With the service and the widgets gone, as in a plugin reload, the Store spawns nothing, and the views that come back show what changed meanwhile, through the same Store (`test/startup.sh`). It failed when the Store read again only before its first snapshot.

## Tests

- The QML scripts replace the binary with `test/lib/stub-db.sh`, which logs each request in `db.log` with the ops it carries and holds or fails the requests a script names. `sqlite3` stays as the oracle and as someone editing the file by hand.
- `test/lib/v0.sql` is the frozen schema of a database from before versioning. The scripts write their rows on it, and the binary migrates the file when it opens it.
- `test/lib/legacy-db.js` keeps the SQL of before the binary, only as the oracle of the parity tests (`test/bin-parity.test.mjs`, `test/bin-cells.test.mjs`, `test/bin-schema.test.mjs`). The plugin never loads it.
