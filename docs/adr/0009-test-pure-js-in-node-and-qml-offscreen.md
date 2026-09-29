# Test pure JS in Node and QML in an offscreen shell

Quickshell has no unit test runner. `data/Db.js`, `ui/Item.js` and the other `.pragma library` files have no QML imports, and `test/lib/load-qml-lib.mjs` loads them in Node by stripping the pragma line, so `node --test` covers the request and the coercion of the data layer and the item wording. The database tests drive the committed binary (ADR-0018) against throwaway databases and read back what it wrote with `sqlite3`. The QML is tested by `test/render.sh`, `test/behavior.sh` and the other offscreen scripts, which start `qs -p` on a throwaway config that links the installed shell's kit, with a throwaway `XDG_DATA_HOME` holding a seeded database and `test/lib/stub-db.sh` in place of the binary.

## Consequences

- `Db.js` and `Item.js` must not use `.import` or QML globals, or the Node loader breaks.
- The unit tests need `sqlite3` and the binary for this machine in `bin/`. The QML tests need `qs`, `sqlite3` and the Omarchy shell installed under `$OMARCHY_PATH` (default `/usr/share/omarchy`).
