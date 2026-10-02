# Version the schema with ordered migrations

The live database is kept on purpose (ADR-0003), and `CREATE TABLE IF NOT EXISTS` never changes a table that already exists, so a schema built only from `CREATE ... IF NOT EXISTS` could never add a column to it. The schema is the list `Steps` in `db/Schema.cs`, and SQLite's `PRAGMA user_version` records how much of it a database has. Entry `i` takes a database from version `i` to `i + 1`. Every request to the binary opens the file and runs `Schema.Migrate` first: it reads the version, and when the file is behind, it takes `BEGIN IMMEDIATE`, reads the version again and runs every entry above it in that transaction, ending at `Steps.Length` (ADR-0018).

## Consequences

- A schema change appends one entry to `Steps`, rebuilds `bin/` and changes nothing else. A shipped entry never changes, because databases already past it would never run the new text.
- The text of each entry is the text the migrations of `data/Db.js` ran before the binary, character for character, so `sqlite_master` reads the same. `test/bin-schema.test.mjs` compares a new file and a migrated one against what those migrations built, frozen in `test/fixtures/parity/schema.json`.
- The first entry is the schema from before versioning, with `IF NOT EXISTS`, because databases made then have its tables at version 0. `test/lib/v0.sql` freezes it for the tests. Later entries run once per database and do not need to be idempotent.
- Several processes can open a file that is behind at once. The version read again under the write lock makes only the first one migrate, and the others find the current version and go on. `test/bin-schema.test.mjs` opens one new file from six processes.
- The fourth entry creates the `alarms` table (ADR-0015). The fifth creates the `settings` table and its one row (ADR-0016).
- A request on a file at the current version only reads the version, so a second start changes nothing in the file.
- A database at a version above `Steps.Length`, written by a newer Omanotes, is used as it is.
- The QML test scripts write their rows on `test/lib/v0.sql` and open the file with the binary, so they start at the current version with rows that went through every migration. `test/startup.sh` checks the version a missing database ends at.
