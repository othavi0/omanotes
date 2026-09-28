# Keep the settings in one typed row that every Db reads

The Settings tab changes state that lives in different places: the alarm sound and volume and the new-alarm defaults, read by the one service (ADR-0015); the Keep choice for history, which deletes rows every widget shows; and the update check. It is written from a panel, and there is one panel per monitor. Migration 5 adds a `settings` table with exactly one row (`CHECK (id = 1)`) and one typed column per setting, each with a `CHECK` for its range and a `DEFAULT` for a fresh row. `SETTINGS` in `data/Db.js` is the only JS description of the record: it drives the read (`settingsSql`, which also returns the file size), the write (`setSettingsSql`) and the fallbacks (`parseSettings`).

`data/DbCore.qml` reads the row with the watcher (ADR-0004), so every widget's `ItemsDb` and the service's `AlarmsDb` see the same settings, with or without a service. `setSettings(patch)` lays the patch over the row at once and queues one upsert of only the keys in the patch. A read drops a key's overlay once it started after that write ended, as the alarm store does (ADR-0015). A failed write drops its keys, so the control shows the file again, and the toast says "Setting not saved" with sqlite3's reason. It is not retried: nothing depends on a setting landing.

## Considered options

- Bar-entry config in `shell.json` through `updateEntryInline`. A write there rebuilds the bar and closes the panel, the service would read config it does not own, and the tests and older shells have no store.
- The service as the only writer, as for alarms. Per-key absolute upserts are already safe with several writers, and History, Data and Updates would then depend on a service that older shells lack.
- A key-value table. It needs a type per value in JS and gives up the `CHECK` constraints that refuse a hand edit out of range.

## Consequences

- Two panels writing different keys never undo each other; the same key takes the last click, which is what the user did last.
- The service reads the row and never writes it. The ring takes its sound, its volume and the Sound switch from it, and a new alarm takes its snooze and ring lengths from the row of the Db that writes it, so a changed default reaches the next draft before the reload.
- Every Settings control is a click or a release: a Segment, a Stepper, a sound row, a slider. There is no text to leave, so each saves at once and ADR-0007 does not apply. There is no Save or Discard.
- The sound catalog lives in `data/Sound.js`, not in a `CHECK`, so adding a sound needs no migration. A key the catalog does not know plays the default. `SETTINGS` repeats the default key as the sound's fallback, since `Db.js` cannot import under Node, and `test/sound.test.mjs` holds the two equal.
- The `DEFAULT`s repeat the fallbacks of `SETTINGS` (volume 100, snooze 9, ring 5). A shipped migration never changes (ADR-0011), so `SETTINGS` is the living source.
- A shorter Keep prunes history in the same transaction as the setting. Entries also age while nothing is written, so opening the panel prunes when the oldest entry, carried by the counts read, is past the cutoff. An open with nothing to prune writes nothing and fires no watcher.
- Each `ItemsDb` runs one more read per reload, and the `AlarmsDb` one more too.
