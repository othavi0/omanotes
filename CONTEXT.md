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
The first click on a destructive button: Delete on an item, the trash on a history entry, or Clear history. A second click on the same button within two seconds confirms it. Selecting another row, switching tabs or closing the panel cancels it.
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
The popout opened from the bar icon, with the Items, Alarms and History tabs.
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

**Scratchpad**:
The legacy name of the database file and of the IPC target, kept so existing notes and scripts keep working.
_Avoid_: using it as the name of the product or of the data layer
