# Omanotes

![Omanotes preview](preview.png)

Notes and todos in one keyboard-driven panel on the Omarchy bar. Everything is stored in a local SQLite database, and a History tab logs each change.

## Features

- One list for notes and todos. Unread notes and pending todos sort first, then the most recently updated.
- The right-hand pane is the editor: a title field and a body. Leaving the editor saves it.
- Keyboard-driven, with a hint bar that shows the keys for the current context.
- A History tab that logs every change (`added`, `edited`, `completed`, `reopened`, `converted`, `deleted`). Entries can be deleted one by one or cleared.
- The panel reloads when the database file changes, so edits from the IPC or from `sqlite3` show up without reopening it.
- An IPC target to add, list, toggle and remove items from scripts.

## Install

```sh
omarchy plugin add https://github.com/othavi0/omanotes.git --enable
```

## Remove

```sh
omarchy plugin remove othavi0.omanotes
```

## Keys

Items tab, list:

| Key | Action |
|---|---|
| `j` / `k`, `↓` / `↑` | Move the selection |
| `Enter`, `l`, `→`, `Tab` | Edit the selected item, or start a note draft when nothing is selected |
| `n`, `a` | New note draft |
| `Space`, `c` | Toggle status (read/unread, completed/pending) |
| `d` `d` | Delete. The second press must come within 2 seconds, and moving the selection cancels the first |
| `/` | Focus search |
| `f` | Cycle the filter: all, notes, todos |
| `1` / `2` | Show the Items tab or the History tab |
| `Esc` | Cancel an armed delete, or close the panel |

Letter and number shortcuts do nothing while `Ctrl`, `Alt` or `Super` is held, so `Ctrl+C` in the list does not toggle the selected item. Letters still work with Caps Lock on. In the search field and the editor, `1` and `2` are typed as text.

Items tab, editor:

| Key | Title field | Body |
|---|---|---|
| `Enter` | Move to the body | Save and return to the list |
| `Shift+Enter` | | New line |
| `Tab` | Move to the body | Save and return to the list |
| `Shift+Tab` | Save and return to the list | Move to the title |
| `Esc` | Save and return to the list | Save and return to the list |
| `Shift+Esc` | Discard and return to the list | Discard and return to the list |
| `Ctrl+T` | On a draft, convert between note and todo | On a draft, convert between note and todo |

A draft with a body and no title can't be saved. It stays open with the warning "New item needs a title" until you type a title or discard it.

Search field: `Enter`, `Tab` or `Shift+Tab` return to the list, `Esc` clears the search and returns. While a draft is open, they return to the draft's title instead.

History tab: `j` / `k` move, `d` `d` deletes an entry and selects the next one, `c` `c` clears the whole history, `1` / `2` show the Items tab or the History tab, `Esc` cancels an armed delete or clear, or closes the panel. The Clear history button also needs a second click. As in the list, the second press must come within 2 seconds, moving the selection cancels the first, and the letter and number shortcuts do nothing with `Ctrl`, `Alt` or `Super` held.

The History tab shows a note marked read as `read` and a note marked unread as `unread`. The database stores them as `completed` and `reopened`, like a todo's.

## IPC

The target is `scratchpad` (a legacy name, see [ADR-0003](docs/adr/0003-keep-the-scratchpad-name-for-data-and-ipc.md)). Every method takes all its arguments, so pass `""` for an empty body:

```sh
qs -p /usr/share/omarchy/shell ipc call scratchpad addNote "Buy coffee" ""
qs -p /usr/share/omarchy/shell ipc call scratchpad addTodo "Renew the domain" "Due day 30"
qs -p /usr/share/omarchy/shell ipc call scratchpad listTodos
```

| Method | What it does | Replies |
|---|---|---|
| `addNote(title, body)`, `addTodo(title, body)` | Adds a note or a todo | `{"ok":true}`, `{"ok":false,"error":"title is required"}` for an empty title |
| `listNotes()`, `listTodos()` | Lists every note or every todo, from the bar widget's last reload | A JSON array of `{id, type, title, body, status}` |
| `toggleStatus(id)` | Toggles the status of any item, note or todo | `{"ok":true}`, `{"ok":false,"error":"item not found: <id>"}` |
| `toggleTodo(id)` | The old name of `toggleStatus`, kept for existing scripts. It also toggles notes | Same as `toggleStatus` |
| `remove(id)` | Deletes an item | `{"ok":true}`, `{"ok":false,"error":"item not found: <id>"}` |
| `clearHistory()` | Deletes every history entry and keeps the items | `{"ok":true}` |
| `ping()` | Checks that the bar widget answers | `{"ok":true}` |
| `open()`, `close()`, `show()`, `hide()`, `toggle()` | Opens, closes or toggles the panel. `show` and `hide` are the same as `open` and `close` | Nothing |

Every method except `ping` and the panel methods can also reply `{"ok":false,"error":"not ready"}` while the database is starting.

Writes are asynchronous. `{"ok":true}` means the write is queued. A write that fails later is logged to the journal with the `omanotes db:` prefix. `toggleStatus`, `toggleTodo` and `remove` look the id up in the bar widget's last reload, so an item added or deleted a moment before can still be missing or found. A `list*` call right after an `add*` can miss the new item until the bar widget reloads.

## Data

The database is `$XDG_DATA_HOME/omarchy/scratchpad.db` (`~/.local/share/omarchy/scratchpad.db` by default), stored as plain SQLite. The schema is `SCHEMA` in `data/Db.js`: an `items` table for notes and todos and a `history` table. The plugin applies it at start, and the test harness seeds its database from the same constant.

## Development

- `npm run validate` runs `omarchy plugin validate .`.
- `npm test` runs `node --test test/`, then `test/render.sh`, `test/behavior.sh`, `test/panel.sh` and `test/teardown.sh`. The last four start Quickshell offscreen and need `qs`, `sqlite3` and the Omarchy shell installed.

Design decisions are in [`docs/adr/`](docs/adr/) and the project vocabulary is in [`CONTEXT.md`](CONTEXT.md).

## License

[Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for copyright and attribution.
