# Omanotes

Omarchy shell plugin (Quickshell/QML) with a bar widget and a service: notes and todos in one list, an Alarms tab, a History tab, a Settings tab, SQLite through `omanotes-db`, a C# NativeAOT binary spawned once per request (ADR-0018).

## Layout

- `BarWidget.qml` is the bar-widget entry point, the popout identity and the IPC handler. It loads `Panel.qml` on demand and unloads it when idle (ADR-0019).
- `Service.qml` is the service entry point, mounted once per shell: the alarm clock, the ring card, the sound, the missed notification and the only writer of the `alarms` table (ADR-0015).
- `data/Store.qml` is a singleton (`data/qmldir`), the one door to the database for the whole shell: the write queue, two lanes of `data/Lane.qml` (writes, reads), the file watcher and the one copy of the snapshot. With no view attached it holds no rows and reads nothing; queued writes still go out. `data/ItemsDb.qml` (one per bar widget) and `data/AlarmsDb.qml` (the service's) are views over it: each attaches as a widget or as the service, reads items, history and alarms from its snapshot and queues its writes in it as that side. Both read the one `settings` row, and only `ItemsDb` writes it (ADR-0016). `data/Db.js` has no SQL: `SETTINGS`, the coercion of the snapshot's raw cells, the overlays, the request the Store writes on stdin, `reply` and the words of each error. `data/Alarm.js` is the pure alarm maths and `data/Sound.js` the alarm sound catalog, which the service rings from. `data/update.sh` does the self-update, `data/Update.js` reads its results and `data/Updater.qml` runs it (ADR-0017).
- `db/` is the C# source of `omanotes-db`: every SQL statement, the migrations (`db/Schema.cs`), the search fold (`db/Schema/search_map.tsv`) and the wire (`db/Wire.cs`, with `Protocol.Current` and `Min`). `bin/omanotes-db.x86_64` and `bin/omanotes-db.aarch64` are the committed builds, described by `bin/BUILD.json`. `tools/` builds and checks them.
- `ui/` holds the tabs, the editors, the ring card and the panel's own controls. `ui/Item.js` holds the wording that depends on type and status, `ui/Alarms.js` every alarm string and `ui/Settings.js` every Settings string.
- `test/` has Node unit tests for the `.pragma library` files, `bin-*.test.mjs` for the committed binary (the parity tests hold it to the SQL of before, kept only as an oracle in `test/lib/legacy-db.js`), `update.sh` for `data/update.sh` against a throwaway origin, and six offscreen Quickshell scripts: `render.sh` checks control heights and renders each scene, `behavior.sh` drives `ItemsTab`, `panel.sh` drives `BarWidget` and `Panel` through IPC and the pointer without the service, and holds the gates of ADR-0019, `alarm.sh` drives `Service.qml`, three bar widgets and the Alarms tab with the clock driven by the test, `startup.sh` starts one `BarWidget` per monitor and the service against a missing database and holds the gates of ADR-0018, and `teardown.sh` checks that `panel.sh` leaves no `qs` running when it fails. The scripts put `test/lib/stub-db.sh` in place of the binary, which logs each request in `db.log`, and seed their rows on `test/lib/v0.sql`.

## Commands

- `npm test` runs everything, `tools/verify-bin.sh --check` included. It needs `qs`, `sqlite3` and the Omarchy shell under `$OMARCHY_PATH` (default `/usr/share/omarchy`). The aarch64 test skips without `qemu-aarch64-static` and the sysroot; `OMANOTES_REQUIRE_ARM=1` makes that a failure, for a release.
- `node --test test/` runs only the unit tests.
- `npm run validate` runs `omarchy plugin validate .`.
- `npm run build:db` (`tools/build.sh`) rebuilds `bin/` for x86_64 and aarch64 and writes `bin/BUILD.json`. It needs the .NET SDK of `db/global.json`, and the aarch64 sysroot that `tools/sysroot.sh` unpacks.
- `npm run verify:bin:rebuild` builds again into a temporary folder and compares the bytes of both binaries. It exits 2 when the toolchain is not the one `bin/BUILD.json` records.

## Rules

- Use the vocabulary in `CONTEXT.md`, in code and in user-facing text.
- Read the ADRs in `docs/adr/` that touch the area before changing it. Say so when a change contradicts one.
- All SQL lives in `db/` and runs in the binary; nothing in `data/` or `ui/` builds SQL (ADR-0018). A schema change appends a step to `db/Schema.cs` (ADR-0011). `Db.js`, `Alarm.js`, `Sound.js`, `Update.js`, `Item.js`, `Alarms.js` and `Settings.js` stay free of QML imports so Node can load them (ADR-0009).
- Only `tools/build.sh` writes `bin/`. A change to `db/`, `tools/build.sh` or `tools/sysroot.lock` goes in the same commit as the rebuilt binaries and `bin/BUILD.json`, or `npm test` fails in `tools/verify-bin.sh --check`.
- A release that raises `Protocol.Current` in `db/Wire.cs` keeps `Min = Current - 1` and raises `PROTOCOL` in `data/Db.js` to match.
- Every spawn of the binary goes through `data/Lane.qml`, and only `data/Store.qml` runs Lanes.
- Only `Service.qml` writes the `alarms` table, through its own `Data.AlarmsDb` (ADR-0015), and the binary refuses alarm writes that are not the service's. Alarm time inside the service comes from `tick(nowMs)`, never `Date.now()`; only the player latch reads the wall clock.
- The database file and IPC target keep the `scratchpad` name (ADR-0003). `NOTICE` is not removed (ADR-0010).

## Agent skills

### Issue tracker

Issues live in GitHub Issues on othavi0/omanotes, used through `gh`. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default triage labels, all created on GitHub. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
