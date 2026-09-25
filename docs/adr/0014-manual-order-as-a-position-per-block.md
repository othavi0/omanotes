# Keep the manual order as a position inside each block

The list used to be ordered by `status ASC, updated_at DESC`, so the last item edited jumped to the top and the user could not choose the order. The Order in `CONTEXT.md` keeps the two blocks (unread notes and pending todos first, read notes and completed todos after) and lets the user set the order inside each block by dragging. Each item stores an integer `position`, and the list reads `ORDER BY status ASC, position ASC, id DESC` (`listSql` in `data/Db.js`). The panel, `allItems` and the IPC `list*` methods all read that order, and every filter shows the same order.

## Consequences

- The third entry of `MIGRATIONS` adds the column and numbers each block from 1 in the order the list showed before (`updated_at DESC, id DESC`), so nothing moves on the first start. It also replaces the index `idx_items_sort` with `idx_items_order` on `(status, position)`.
- A new, reopened, read or completed item takes the top of its block: `addSql` and `setStatusSql` give it the block's smallest position minus 1 (`topOfBlockSql`). No other row is written, so positions can go below zero. `setStatusSql` leaves the position alone when the status does not change. `updateSql` and `convertTypeSql` do not touch the position.
- A drop becomes a move relative to one other item of the same block: `moveSql(id, anchorId, after)` puts the item just before the anchor, or just after it, and numbers that block 1, 2, 3 in one `UPDATE` inside the usual transaction (ADR-0001). The other block is not written. The move writes nothing, and `SELECT changes()` prints 0, when either item is missing, both are the same item or they sit in different blocks. `Db.qml` then reports "item not found" like the other one-item writes.
- In Notes or Todos the anchor is a visible row: the row just below the drop point, or the last visible row of the block when the drop is past it (`dropMove` in `ui/Item.js`). The hidden rows keep their places and their relative order.
- A move is not an action (`CONTEXT.md`), so it writes no history entry and leaves `updated_at` alone.
- `Db.move` reorders its cached `items` right away, so the dropped row does not jump back until the reload. The reload after the write replaces that list.
- A reload during a drag rebuilds every row of the list, so the drag ends there without a move. An alarm write, from a tick or from the Alarms tab, is one more cause of a reload (ADR-0015), so a ring that lands during a drag ends it too.
- A draggable row keeps a vertical drag from the list, so the list does not scroll under a drag. While the search has text the rows do not drag, and a vertical drag scrolls the list.
- Rows written with `sqlite3` outside Omanotes get the column default, 0, and rows with the same position fall back to the newest id first. Unlike the search copy (ADR-0012), no trigger places them.
