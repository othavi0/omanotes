# Parity fixtures

What the SQL of before the binary left and read, run once and frozen (ADR-0018). `test/bin-parity.test.mjs`, `test/bin-schema.test.mjs` and `test/bin-cells.test.mjs` hold the binary to them.

- `writes.json` holds the five tables after each write step, the id of each insert, the found of each write to one item and the ids of each search.
- `schema.json` holds `sqlite_master`, `user_version` and the rows of a new file and of a migrated v0 file, and the first migration.
- `cells.json` holds the text `sqlite3 -json` printed for each hostile cell in the old reads, and what the old parsers made of it.

## How they were made

`node test/lib/freeze-parity.mjs` at commit 4ead611, with sqlite3 3.53.4. That commit is the last one with `test/lib/legacy-db.js` and the helpers the generator imports. To make them again, check out 4ead611 in a separate worktree and run the generator there.

## After a new step in `Steps`

Nothing here changes. The tests compare each live row only in the columns of its frozen row, and only the `sqlite_master` entries the fixture holds. A frozen table may end in columns a later step added. A new column, table or index is not the old SQL's, so its own tests state what it does.

A step that changes what an old column holds, or the text of an old entry, makes a parity test fail. That is a change of behavior. Edit the frozen value by hand in the same commit, and say why in the commit message.
