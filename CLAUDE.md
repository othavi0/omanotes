# Omanotes

Omarchy shell bar-widget plugin (Quickshell/QML): notes and todos in one list, a History tab, SQLite through the `sqlite3` CLI.

## Layout

- `BarWidget.qml` is the plugin entry point, the popout identity and the IPC handler. It loads `Panel.qml`.
- `data/Db.qml` runs every database operation, and `data/Db.js` builds all SQL and parses results.
- `ui/` holds the tabs, the editor and the panel's own controls. `ui/Item.js` holds the wording that depends on type and status.
- `test/` has Node unit tests for the `.pragma library` files and two offscreen Quickshell scripts.

## Commands

- `npm test` runs everything. It needs `qs`, `sqlite3` and the Omarchy shell under `$OMARCHY_PATH` (default `/usr/share/omarchy`).
- `node --test test/` runs only the unit tests.
- `npm run validate` runs `omarchy plugin validate .`.

## Rules

- Use the vocabulary in `CONTEXT.md`, in code and in user-facing text.
- Read the ADRs in `docs/adr/` that touch the area before changing it. Say so when a change contradicts one.
- All SQL is built in `data/Db.js` (ADR-0002). `Db.js` and `Item.js` stay free of QML imports so Node can load them (ADR-0009).
- The database file and IPC target keep the `scratchpad` name (ADR-0003). `NOTICE` is not removed (ADR-0010).

## Agent skills

### Issue tracker

Issues live in GitHub Issues on othavi0/omanotes, used through `gh`. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default triage labels, all created on GitHub. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
