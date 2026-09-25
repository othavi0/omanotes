# One items table for notes and todos

Notes and todos have the same fields and the user can convert one into the other, so both live in one `items` table with a `type` column (`note` or `todo`) and a two-state `status` (0 or 1) whose meaning depends on the type: unread/read for notes, pending/completed for todos. Status 0 sorts first, so the list shows what still needs attention on top.

## Considered options

- Two tables. Converting would copy the row between tables and change its id, which breaks selection by id and the history.

## Consequences

- The per-type wording of status lives in `ui/Item.js`.
- Ids use `AUTOINCREMENT`, so a deleted id is never reused and the UI can keep ids across reloads.
