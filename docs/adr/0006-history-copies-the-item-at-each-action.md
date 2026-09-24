# History copies the item at each action

Each write that changes an item also inserts a `history` row with a copy of the item's `type` and `title` at that moment and the action name (`data/Db.js`). The row has no foreign key and no item id, so the log survives when the item is deleted and shows what the item looked like then.

## Consequences

- A history entry cannot link back to its item. An `edited` entry carries the title after the edit.
- The history row is written in the same SQL string as the item change, so it inherits the atomicity gap described in ADR-0001.
