# Test pure JS in Node and QML in an offscreen shell

Quickshell has no unit test runner. `data/Db.js` and `ui/Item.js` are `.pragma library` files with no QML imports, and `test/lib/load-qml-lib.mjs` loads them in Node by stripping the pragma line, so `node --test` covers the SQL builders and item wording. The SQL tests run each statement against a throwaway SQLite database and assert the rows it leaves. The QML is tested by `test/render.sh` and `test/behavior.sh`, which start `qs -p` offscreen on a throwaway config that links the installed shell's kit, with a throwaway `XDG_DATA_HOME` holding a seeded database.

## Consequences

- `Db.js` and `Item.js` must not use `.import` or QML globals, or the Node loader breaks.
- The unit tests need `sqlite3`. The QML tests need `qs`, `sqlite3` and the Omarchy shell installed under `$OMARCHY_PATH` (default `/usr/share/omarchy`).
