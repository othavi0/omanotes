# Omanotes

![Omanotes preview](preview.png)

Notes, todos and alarms in one panel on the Omarchy bar. Everything is stored in a local SQLite database, and a History tab logs each change to an item.

## Features

- One list for notes and todos. Unread notes and pending todos come first, read notes and completed todos after them, and you set the order inside each of those two blocks by dragging.
- The right-hand pane is the editor: a title field and a body. Leaving the editor saves it.
- Driven by the mouse, with Esc to close the panel.
- An Alarms tab. Each alarm has a time, a label, the days it repeats, a snooze length and a ring length. The bar shows the next alarm, and a due alarm rings on a card under the bar.
- A History tab that logs every change to an item (`added`, `edited`, `completed`, `reopened`, `converted`, `deleted`). Entries can be deleted one by one or cleared. Alarms are not logged.
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
- Drag a row, from anywhere on it, to put it somewhere else in its block. The drag starts after the pointer moves 6 px, so a click still opens the row, or toggles it on the status icon. A new or reopened item goes to the top of the first block, and an item you mark read or complete goes to the top of the second. Editing or converting an item leaves it where it is. In Notes or Todos, a dropped row lands next to the rows you see and the hidden ones keep their places. Rows don't drag while the search field has text.
- The editor saves when you leave it: another row, the Save button, another tab or closing the panel. Discard throws the changes away. In the title, `Tab` and `Enter` move to the body; in the body, `Enter` starts a new line and `Shift+Tab` goes back to the title.
- A draft with a body and no title can't be saved. It stays open with the warning "New item needs a title" until you type a title or discard it.
- The buttons under the editor toggle the status, convert between note and todo, copy the item and delete it.
- In History, a trash button shows on the row under the pointer.

Delete, the History trash and Clear history each need a second click on the same button, which reads Confirm, within 2 seconds. Selecting another row, switching tabs or closing the panel cancels the first click.

The History tab shows a note marked read as `read` and a note marked unread as `unread`. The database stores them as `completed` and `reopened`, like a todo's.

## Alarms

Open the panel, pick **Alarms** and press **+ Alarm**, or choose Alarm in the New menu. Type the time as `07:30` or `0730`, then set a label, the days it repeats, how long a snooze lasts and how long it rings. Leaving the editor saves the alarm. An alarm with no repeat days rings once and switches itself off. The switch on each row turns the alarm off and on, and switching it on arms it from now, so a time that passed while it was off does not ring.

The bar chip shows the next alarm: `07:30` when it is today, `Sat 07:30` on another day, and the snooze time after a snooze. When an alarm is due, a card drops under the bar on every screen, the chip turns to a bell with the alarm's label, and a sound loops. Snooze or Stop it on the card, or click the chip. If you do nothing, the alarm snoozes itself after its ring length, up to 3 times. The panel stays closed and the card takes no keyboard focus.

An alarm found more than 10 minutes late, after the computer slept, does not ring. You get one notification that lists every missed alarm.

The sound is `/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga`, played by the first of `pw-play`, `paplay`, `mpv` and `ffplay` that is installed. When none can play it, the alarm rings silently and the journal says so.

The alarms are kept once per shell by the plugin's service, so several monitors share one clock and one ring. In a shell without the service, the tab says so and the chip shows the note glyph alone.

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
| `listNotes()`, `listTodos()` | Lists every note or every todo in the panel's order, from the bar widget's last reload | A JSON array of `{id, type, title, body, status}` |
| `toggleStatus(id)` | Toggles the status of any item, note or todo | `{"ok":true}`, `{"ok":false,"error":"item not found: <id>"}` |
| `toggleTodo(id)` | The old name of `toggleStatus`, kept for existing scripts. It also toggles notes | Same as `toggleStatus` |
| `remove(id)` | Deletes an item | `{"ok":true}`, `{"ok":false,"error":"item not found: <id>"}` |
| `clearHistory()` | Deletes every history entry and keeps the items | `{"ok":true}` |
| `ping()` | Checks that the bar widget answers | `{"ok":true}` |
| `open()`, `close()`, `show()`, `hide()`, `toggle()` | Opens, closes or toggles the panel. `show` and `hide` are the same as `open` and `close` | Nothing |

Every method except `ping` and the panel methods can also reply `{"ok":false,"error":"not ready"}` while the database is starting.

Writes are asynchronous. `{"ok":true}` means the write is queued. A write that fails later is logged to the journal with the `omanotes db:` prefix. `toggleStatus`, `toggleTodo` and `remove` look the id up in the bar widget's last reload, so an item added or deleted a moment before can still be missing or found. A `list*` call right after an `add*` can miss the new item until the bar widget reloads.

## Data

The database is `$XDG_DATA_HOME/omarchy/scratchpad.db` (`~/.local/share/omarchy/scratchpad.db` by default), stored as plain SQLite. The schema is the `MIGRATIONS` list in `data/Db.js`: an `items` table for notes and todos with a `position` for the order, a `history` table, a folded copy of each title and body for search, and an `alarms` table whose instants are epoch milliseconds and whose `days` is a bitmask of weekdays with bit 0 for Sunday. At start the plugin runs every migration above the database's `user_version` in one transaction (ADR-0011), and the test harness seeds its database the same way. An alarm row inserted with `sqlite3` is armed at its insert time, so it does not ring for a time that passed before it existed.

## Development

- `npm run validate` runs `omarchy plugin validate .`.
- `npm test` runs `node --test test/`, then `test/render.sh`, `test/behavior.sh`, `test/panel.sh`, `test/alarm.sh`, `test/startup.sh` and `test/teardown.sh`. The unit tests need `sqlite3`. The other six start Quickshell offscreen and need `qs`, `sqlite3` and the Omarchy shell installed.

Design decisions are in [`docs/adr/`](docs/adr/) and the project vocabulary is in [`CONTEXT.md`](CONTEXT.md).

## License

[Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for copyright and attribution.
