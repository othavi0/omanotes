# Build all SQL as text in Db.js

The sqlite3 CLI takes SQL as a plain string, so there are no bound parameters (ADR-0001). Every statement is built in `data/Db.js` and nowhere else: text values go through `q()`, which doubles single quotes, and search patterns go through `likeEscape()` with an explicit `ESCAPE '\'`. Keeping the builders in one `.pragma library` file with no QML imports also lets Node test them (ADR-0009).

## Consequences

- A view or `Db.qml` that concatenates SQL itself breaks this rule. Add a builder to `Db.js` instead.
- Numeric ids are interpolated after `Number()`. An id that is not a number reaches SQL as `NaN` today, so callers must validate ids before they get here.
