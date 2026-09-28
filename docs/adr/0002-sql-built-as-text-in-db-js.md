# Build all SQL as text in Db.js

The sqlite3 CLI takes SQL as a plain string, so there are no bound parameters (ADR-0001). Every statement is built in `data/Db.js` and nowhere else: text values go through `q()`, which doubles single quotes, and search patterns go through `likeEscape()` with an explicit `ESCAPE '\'`. Keeping the builders in one `.pragma library` file with no QML imports also lets Node test them (ADR-0009).

## Consequences

- A view or one of the `data/*Db.qml` files that concatenates SQL itself breaks this rule. Add a builder to `Db.js` instead.
- Ids are interpolated as text. `sqlId()` throws on anything but a whole number, so an invalid id fails before any statement is built.
