# Commit when the user leaves the editor

The editor sits next to the list and the user moves between items all the time, so there is no save prompt and no save on each keystroke. Every way out of the editor except the Discard button commits: keys, the Save button, clicking elsewhere, switching tabs and closing the panel (`commitEditor` in `ui/MainTab.qml`). The editor remembers the id it was opened for (`editingId` in `ui/EditorPane.qml`), so a commit that runs after the selection moved still writes to the right item.

## Consequences

- A new way to leave the editor must go through the same commit, or the user loses text. Two paths break this today: a draft with a body and an empty title is dropped, and the New button with a draft open replaces it without committing.
- An existing item whose title was cleared keeps its saved title and still saves the body.
