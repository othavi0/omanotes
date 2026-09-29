# Build all SQL as text in Db.js

Superseded by [ADR-0018](0018-one-store-and-the-omanotes-db-binary.md): the SQL lives in `db/`, bound by the binary, and `data/Db.js` holds none. `test/lib/legacy-db.js` keeps the SQL this record describes, as the oracle of the parity tests.

The sqlite3 CLI takes SQL as a plain string, so there are no bound parameters (ADR-0001). Every statement is built in `data/Db.js` and nowhere else: text values go through `q()`, which doubles single quotes, and search patterns go through `likeEscape()` with an explicit `ESCAPE '\'`. Keeping the builders in one `.pragma library` file with no QML imports also lets Node test them (ADR-0009).

## Consequences

- A view or one of the `data/*Db.qml` files that concatenates SQL itself breaks this rule. Add a builder to `Db.js` instead.
- Ids are interpolated as text. `sqlId()` throws on anything but a whole number, so an invalid id fails before any statement is built.
