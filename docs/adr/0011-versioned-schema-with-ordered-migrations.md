# Version the schema with ordered migrations

The live database is kept on purpose (ADR-0003), and `CREATE TABLE IF NOT EXISTS` never changes a table that already exists, so a schema built only from `CREATE ... IF NOT EXISTS` could never add a column to it. The schema is the list `MIGRATIONS` in `data/Db.js`, and SQLite's `PRAGMA user_version` records how much of it a database has. Entry `i` takes a database from version `i` to `i + 1`. At start-up, `data/DbCore.qml` reads the version (`initCommand`), and `migrateSql(version)` runs every entry above it in one transaction that ends by setting the version to `MIGRATIONS.length`.

## Consequences

- A schema change appends one entry to `MIGRATIONS` and changes nothing else. A shipped entry never changes, because databases already past it would never run the new text.
- An entry is its list of statements, or a function that returns the list when building it is costly. `migrateSql` calls the function only for a database below that entry, so a start-up at the current version does not pay for it (ADR-0012).
- The first entry is the schema from before versioning, with `IF NOT EXISTS`, because databases made then have its tables at version 0. Later entries run once per database and do not need to be idempotent.
- Each widget starts its own `Db` (ADR-0004), so two start-ups can read the same version. The transaction first checks that the version is still the one it read, and fails with `version_changed` otherwise, writing nothing. `DbCore.qml` then reads the version again instead of reporting an error. Any other failure is reported and retried with back-off.
- The fourth entry creates the `alarms` table (ADR-0015). The alarm service's `Db` races the migration with the widgets' Dbs, so a start with N monitors runs N + 1 migration attempts, and `test/startup.sh` counts them.
- A start-up at the current version only reads, so a second start changes nothing in the file.
- A database at a version above `MIGRATIONS.length`, written by a newer Omanotes, is used as it is.
- `test/lib/harness.sh` writes its rows on the first entry's schema and then runs `migrateSql(0)`, so the QML tests start at the current version with rows that went through every migration, and `test/startup.sh` checks the version a missing database ends at.
