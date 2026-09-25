# Commit when the user leaves the editor

The editor sits next to the list and the user moves between items all the time, so there is no save prompt and no save on each keystroke. Every way out of the editor except the Discard button commits: the Save button, a choice in the New menu, clicking elsewhere, switching tabs and closing the panel, with Esc or otherwise (`commitEditor` in `ui/ItemsTab.qml`). The editor remembers the id it was opened for (`editingId` in `ui/EditorPane.qml`), so a commit that runs after the selection moved still writes to the right item.

## Consequences

- A new way to leave the editor must go through the same commit, or the user loses text.
- An existing item whose title was cleared keeps its saved title and still saves the body.
- A draft with a body and an empty title cannot be committed, so it stays open with the warning "New item needs a title". Closing the panel keeps it for the next open, and the Discard button throws it away. A draft with neither title nor body is dropped.
- A commit is confirmed by the database, not by the editor. "Added" shows when the add lands. When an add or an edit fails, `Db` emits `writeFailed` with the text it carried, and the editor opens it again as unsaved: the draft, or the item, selected again. When the editor already holds other unsaved text, the failed text waits until that text is committed or discarded. When a filter or search hides the item, the panel clears them to show it. Reopening the panel keeps unsaved text in the editor.
- Deleting the item open in the editor throws its text away first, so the selection that moves to the next row commits nothing.
- An open draft hides the selected row, so while a draft is open, focus meant for the list goes to the draft's title (`focusList` in `ui/ItemsTab.qml`). Clicking a row then keeps the draft in front of the user.
- Opening the panel resets the tab's focus once. The tabs are focus scopes, and the kit's `KeyboardPanel.focusTarget` gives the shown tab keyboard focus when the panel maps, so no delayed retry moves focus away from text typed right after opening (`onOpenedChanged` in `Panel.qml`).
