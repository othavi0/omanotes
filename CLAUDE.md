# Omanotes

Omarchy shell plugin (Quickshell/QML) with a bar widget and a service: notes and todos in one list, an Alarms tab, a History tab, a Settings tab, SQLite through the `sqlite3` CLI.

## Layout

- `BarWidget.qml` is the bar-widget entry point, the popout identity and the IPC handler. It loads `Panel.qml`.
- `Service.qml` is the service entry point, mounted once per shell: the alarm clock, the ring card, the sound, the missed notification and the only writer of the `alarms` table (ADR-0015).
- `data/DbCore.qml` holds what every database object shares: start-up with the migration race, the write queue, the file watcher and read parsing. `data/ItemsDb.qml` (one per bar widget) reads and writes items and history on top of it, and `data/AlarmsDb.qml` (the service's) the alarms. Both read the one `settings` row, and only `ItemsDb` writes it (ADR-0016). `data/Db.js` builds all SQL and parses results. `data/Alarm.js` is the pure alarm maths and `data/Sound.js` the alarm sound catalog, which the service rings from. `data/update.sh` does the self-update, `data/Update.js` reads its results and `data/Updater.qml` runs it (ADR-0017).
- `ui/` holds the tabs, the editors, the ring card and the panel's own controls. `ui/Item.js` holds the wording that depends on type and status, `ui/Alarms.js` every alarm string and `ui/Settings.js` every Settings string.
- `test/` has Node unit tests for the `.pragma library` files, `update.sh` for `data/update.sh` against a throwaway origin, and six offscreen Quickshell scripts: `render.sh` checks control heights and renders each scene, `behavior.sh` drives `ItemsTab`, `panel.sh` drives `BarWidget` and `Panel` through IPC without the service, `alarm.sh` drives `Service.qml`, three bar widgets and the Alarms tab with the clock driven by the test, `startup.sh` starts one `BarWidget` per monitor and the service against a missing database, and `teardown.sh` checks that `panel.sh` leaves no `qs` running when it fails.

## Commands

- `npm test` runs everything. It needs `qs`, `sqlite3` and the Omarchy shell under `$OMARCHY_PATH` (default `/usr/share/omarchy`).
- `node --test test/` runs only the unit tests.
- `npm run validate` runs `omarchy plugin validate .`.

## Rules

- Use the vocabulary in `CONTEXT.md`, in code and in user-facing text.
- Read the ADRs in `docs/adr/` that touch the area before changing it. Say so when a change contradicts one.
- All SQL is built in `data/Db.js` (ADR-0002). `Db.js`, `Alarm.js`, `Sound.js`, `Update.js`, `Item.js`, `Alarms.js` and `Settings.js` stay free of QML imports so Node can load them (ADR-0009).
- Only `Service.qml` writes the `alarms` table, through its own `Data.AlarmsDb` (ADR-0015). Alarm time inside the service comes from `tick(nowMs)`, never `Date.now()`; only the player latch reads the wall clock.
- The database file and IPC target keep the `scratchpad` name (ADR-0003). `NOTICE` is not removed (ADR-0010).

## Agent skills

### Issue tracker

Issues live in GitHub Issues on othavi0/omanotes, used through `gh`. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default triage labels, all created on GitHub. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
