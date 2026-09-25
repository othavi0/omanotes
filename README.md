# Omanotes

![Omanotes preview](preview.png)

Notes and todos in one panel on the Omarchy bar. Everything is stored in a local SQLite database, and a History tab logs each change.

## Features

- One list for notes and todos. Unread notes and pending todos sort first, then the most recently updated.
- The right-hand pane is the editor: a title field and a body. Leaving the editor saves it.
- Driven by the mouse, with Esc to close the panel.
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

## Using the panel

Everything is on screen. `Esc` closes the panel from anywhere in it, and closing saves what the editor holds.

- **New** opens a menu with Note and Todo. Each opens a draft of that type in the editor.
- Click a row to open it in the editor. Its box toggles the status. The search field and the All, Notes and Todos buttons narrow the list.
- The editor saves when you leave it: another row, the Save button, another tab or closing the panel. Discard throws the changes away. In the title, `Tab` and `Enter` move to the body; in the body, `Enter` starts a new line and `Shift+Tab` goes back to the title.
- A draft with a body and no title can't be saved. It stays open with the warning "New item needs a title" until you type a title or discard it.
- The buttons under the editor toggle the status, convert between note and todo, copy the item and delete it.
- In History, a trash button shows on the row under the pointer.

Delete, the History trash and Clear history each need a second click on the same button, which reads Confirm, within 2 seconds. Selecting another row, switching tabs or closing the panel cancels the first click.

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

The database is `$XDG_DATA_HOME/omarchy/scratchpad.db` (`~/.local/share/omarchy/scratchpad.db` by default), stored as plain SQLite. The schema is the `MIGRATIONS` list in `data/Db.js`: an `items` table for notes and todos, a `history` table, and a folded copy of each title and body for search. At start the plugin runs every migration above the database's `user_version` in one transaction (ADR-0011), and the test harness seeds its database the same way.

## Development

- `npm run validate` runs `omarchy plugin validate .`.
- `npm test` runs `node --test test/`, then `test/render.sh`, `test/behavior.sh`, `test/panel.sh`, `test/startup.sh` and `test/teardown.sh`. The unit tests need `sqlite3`. The other five start Quickshell offscreen and need `qs`, `sqlite3` and the Omarchy shell installed.

Design decisions are in [`docs/adr/`](docs/adr/) and the project vocabulary is in [`CONTEXT.md`](CONTEXT.md).

## License

[Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for copyright and attribution.
