# Commit when the user leaves the editor

The editor sits next to the list and the user moves between items all the time, so there is no save prompt and no save on each keystroke. Every way out of the editor except Discard (the button or Shift+Esc) commits: keys, the Save button, the New button, clicking elsewhere, switching tabs and closing the panel (`commitEditor` in `ui/MainTab.qml`). The editor remembers the id it was opened for (`editingId` in `ui/EditorPane.qml`), so a commit that runs after the selection moved still writes to the right item.

## Consequences

- A new way to leave the editor must go through the same commit, or the user loses text.
- An existing item whose title was cleared keeps its saved title and still saves the body.
- A draft with a body and an empty title cannot be committed, so it stays open with the warning "New item needs a title". Esc and Enter leave it open, and Shift+Esc is the keyboard way to throw it away. A draft with neither title nor body is dropped.
- A commit is confirmed by the database, not by the editor. "Added" shows when the add lands. When an add or an edit fails, `Db` emits `writeFailed` with the text it carried, and the editor opens it again as unsaved: the draft, or the item, selected again. It does not do this when the editor already holds other unsaved text, or when a filter hides the item. In those cases only the error toast shows.
- Deleting the item open in the editor throws its text away first, so the selection that moves to the next row commits nothing.
- An open draft hides the selected row, so while a draft is open, focus meant for the list goes to the draft's title (`focusList` in `ui/MainTab.qml`). List keys never act on a row the user cannot see.
