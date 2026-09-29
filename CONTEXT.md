# Omanotes

A mouse-driven panel on the Omarchy bar that keeps short notes and todos in one list, with a log of every change, and rings alarms.

## Language

### Items

**Item**:
A single note or todo. Both kinds share one record and one list.
_Avoid_: entry, record, card

**Type**:
Whether an item is a note or a todo.
_Avoid_: kind, category

**Note**:
An item of type note, read once and then marked read.
_Avoid_: memo, scratch

**Todo**:
An item of type todo, worked on and then marked completed.
_Avoid_: task, to-do

**Status**:
The two-state flag every item has. Its meaning depends on the type (unread/read for notes, pending/completed for todos).
_Avoid_: state, done flag

**Pending**:
A todo that is not completed yet.
_Avoid_: open, in progress

**Completed**:
A todo that is finished.
_Avoid_: done, closed

**Unread**:
A note that has not been marked read.
_Avoid_: new, unseen

**Read**:
A note that has been marked read.
_Avoid_: seen, archived

**Title**:
The required one-line text of an item.
_Avoid_: name, heading

**Body**:
The optional free text under the title.
_Avoid_: content, description, details

### Changes

**Toggle**:
Flipping an item's status (pending to completed, unread to read, and back).
_Avoid_: check, mark (as a verb on its own)

**Convert**:
Changing an item's type while keeping its status.
_Avoid_: change type, switch

**History**:
The log of changes to items, one entry per action, kept after the item itself is deleted. Alarms are not logged.
_Avoid_: activity, audit log, read-only log

**Action**:
What a history entry records: added, edited, completed, reopened, converted or deleted.
_Avoid_: event, change

### Editing

**Draft**:
A new item that exists only in the editor until it is committed.
_Avoid_: new item, unsaved item

**Dirty**:
An existing item whose editor text differs from what is saved.
_Avoid_: modified, changed

**Unsaved**:
A draft, or a dirty item.
_Avoid_: pending (that word is a todo status)

**Commit**:
Saving whatever the editor holds when the user leaves it.
_Avoid_: save as the name of the concept, since "Save" is only a button label

**Discard**:
Throwing away the editor's changes. A discarded draft disappears.
_Avoid_: cancel, revert

**Arm**:
The first click on a destructive button: Delete on an item, the trash on a history entry, Clear history, or a Keep that would remove entries. A second click on the same button within two seconds confirms it. Selecting another row, switching tabs or closing the panel cancels it.
_Avoid_: confirm dialog, prime

### Alarms

**Alarm**:
A time of day with a label, the days it repeats, a snooze length and a ring length. Alarms have their own tab and their own table, apart from items.
_Avoid_: reminder, timer, event

**Repeat**:
The weekdays an alarm rings on, picked Monday first. An alarm with no repeat days rings once and switches itself off after it rings.
_Avoid_: schedule, recurrence, weekly

**Once**:
An alarm with no repeat days.
_Avoid_: one-shot, single, one-time

**On**, **Off**:
The switch of an alarm. An alarm is on when it is enabled or snoozed into the future. Switching it on arms it now, so an occurrence that passed while it was off does not ring.
_Avoid_: enabled, disabled, active (in user-facing text)

**Ring**:
What happens when an alarm is due: a card under the bar on every screen and a sound, for the alarm's ring length. The panel stays closed and the card takes no keyboard focus.
_Avoid_: fire, trigger, go off, notify

**Snooze**:
Putting a ringing alarm off for its snooze length. A ring that nobody answers snoozes itself up to three times.
_Avoid_: postpone, defer, delay

**Stop**:
Ending a ring without a snooze. The Stop button on the card and a click on the bar chip both stop it.
_Avoid_: dismiss, cancel, silence

**Missed**:
An alarm found more than ten minutes past its time, after the computer slept or the shell was down. It does not ring. One notification lists every missed alarm, and each is consumed as if it had rung.
_Avoid_: late, overdue, skipped

**Service**:
The one copy of Omanotes that the shell runs apart from the bar widgets. It keeps the clock, the ring, the sound and every alarm write, so several monitors never mean several rings.
_Avoid_: daemon, backend, controller

### Panel

**Panel**:
The popout opened from the bar icon, with the Items, Alarms and History tabs and the gear for Settings.
_Avoid_: popup, dropdown, window

**Order**:
Where an item sits in the list. Unread notes and pending todos come first, read notes and completed todos after them, and inside each of those two blocks the user sets the order by dragging. One order serves every filter. A new or reopened item enters at the top of the first block, a newly read or completed one at the top of the second, and editing or converting an item leaves it in place.
_Avoid_: sort, rank, priority

**Filter**:
Restricting the list to all items, only notes or only todos.
_Avoid_: tab, view

**Search**:
Restricting the list to items whose title or body contains the typed text, ignoring case and accents.
_Avoid_: query (in user-facing text)

### Settings

**Settings**:
The fourth tab, behind the gear: the alarm sound, the new-alarm defaults, updates, how long history is kept and the database. Every setting saves when it is clicked.
_Avoid_: preferences, options, config

**Defaults**:
The snooze and ring lengths a new alarm starts with. An alarm that exists keeps its own.
_Avoid_: presets, templates

**Test**:
Playing a sound once from Settings, at the volume shown. A ring stops it.
_Avoid_: preview (in user-facing text), sample

**Keep**:
How long history entries stay: forever, 90 days or 30 days. Older entries are removed when the choice changes and when the panel opens.
_Avoid_: retention (in user-facing text), expiry

**Backup**:
A copy of the database next to it, named with the day it was made. A second backup the same day replaces the first.
_Avoid_: export, snapshot

**Check**:
Asking origin/main whether it has commits the plugin folder lacks. The service checks once a day when Check daily is on.
_Avoid_: poll, sync

**Update**:
Pulling those commits into the plugin folder, fast-forward only, once the new version validates in a copy outside it and its `omanotes-db` runs on this machine, then a restart. It refuses a folder with local changes, on another branch, with commits of its own or with untracked files the pull would overwrite. Files git ignores do not count: an ignored file that origin/main starts to track is overwritten, as git does.
_Avoid_: upgrade, install

**Restart**:
Stopping the Omarchy shell and starting a new one, the last step of an update. The shell reloads the plugin when the folder changes, but that reload keeps the code it already compiled, so only a restart loads the new version. When the restart fails, the user runs `omarchy restart shell`.
_Avoid_: reload (for loading new code), relaunch

**Scratchpad**:
The legacy name of the database file and of the IPC target, kept so existing notes and scripts keep working.
_Avoid_: using it as the name of the product or of the data layer

### Data

**Snapshot**:
Everything a reload reads from the database in one go: the settings, the counts, every item, the history, the alarms and what each search matched. Every panel and the service show the last one.
_Avoid_: calling a backup a snapshot, cache

**Store**:
The one door to the database for the whole shell. It holds the last snapshot, queues the writes and watches the file, and every spawn of the database helper goes through it. It holds nothing while no view is attached.
_Avoid_: cache, repository, manager

**Lane**:
One of the Store's two lines of spawns, one for writes and one for reads. Each runs one request at a time, so a write that waits on a lock outside never holds up the list.
_Avoid_: channel, worker, thread

**View**:
What a bar widget or the service holds of the Store: its filter and search, and what it lays over the rows. A view says once, when it attaches, whether it writes as a widget or as the service.
_Avoid_: client, subscriber; the filter is not a view

**Overlay**:
What a view shows over the snapshot for one of its own writes still on its way: a setting, an alarm, a row dropped in a new place. It goes when a snapshot that includes that write lands.
_Avoid_: optimistic update, patch (in user-facing text)

**Stamp**:
The file's change counter when a snapshot was read. A request sends the stamp shown, and the helper answers that nothing changed when the file has not moved since. A file in WAL mode has no stamp.
_Avoid_: version, revision, timestamp

**Covered**:
The last write a shown snapshot includes. A view drops the overlay of a write once the covered write reaches it.
_Avoid_: acknowledged, confirmed
