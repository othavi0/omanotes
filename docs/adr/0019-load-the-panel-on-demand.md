# Load the panel on demand

Each bar widget used to create its `Panel.qml` when the shell started, through a `Loader` that was always active, so a shell with three monitors held three panels that were closed most of the day. Measured offscreen with the service over a copy of a real database, 20 s after the start, a shell without the plugin used 116.7 MB of RSS (23.5 MB anonymous), and with the plugin on three monitors 175.8 MB (71.7 MB anonymous). With the panels switched off the same shell used about 130 MB, so the panels cost about 45 MB on three monitors. On one monitor the plugin used 155.2 MB, 24 MB over the on-demand shell, so the first panel with the compile of `Panel.qml` costs about 24 MB and each further panel about 10 MB.

`BarWidget.qml` now creates its panel only when it is wanted, and drops it again once it has been closed and idle for a while:

- The pointer entering the bar icon (`WidgetButton.tooltipHovered`) sets `panelWanted`, and the `Loader` loads the panel with `asynchronous: true`, so the hover does not stall the bar.
- `open()` loads the panel synchronously when it is not there yet, then opens it. Every path that shows the panel goes through it: a click (`togglePanel`), a click forwarded from another panel's overlay (`triggerPress`), the `scratchpad` IPC (`open`, `show`, `toggle`), and `shell.summon` and `Bar.switchPanelFrom`, which call `open()` on the widget that `Bar.findPanelWidget` picked. The ring card never opens the panel. `open()` sets `asynchronous` to false before it activates the `Loader`. When a hover already started a load in the background, turning `asynchronous` off makes the `Loader` finish that load at once, so a click during the load opens the panel in the same call and is never lost. `onLoaded` turns `asynchronous` back on for the next hover.
- A `Timer` of `panelIdleMs` (60 000 by default) runs while the panel is loaded, closed and not under the pointer. The pointer coming back or the panel opening stops it, and the count starts again from zero. When it fires, the panel is dropped unless something only it can finish is still there, and then the timer starts again.
- The widget keeps what the host needs: `open`, `close` and `opened` for `Bar.findPanelWidget`, `popoutSwitchClosing` and `closeForPopoutSwitch` for `Bar.requestPopout`, and `openPanelIndicatorWidth`. `opened` is false while no panel is loaded, and `close()` does nothing then. `panelItem` is now the `Loader`'s item, so it is null while the panel is unloaded.

## What holds a closed panel

`Panel.busy()` answers whether a closed panel still holds something that would be lost with it. The widget also holds the panel while the Store has any write queued or running (`db.writing`), since the text of a write that fails goes back to the editor of the panel that made it. The Store does not say whose write it is, so a write of another widget or of the service holds the panel too, which only delays the unload.

- Unsaved text in the Items tab: a draft with a body and no title, which closing cannot commit (ADR-0007), or a dirty item. Closing commits a dirty item, so an item is dirty after a close only when its write failed and the editor got the text back.
- A failed write waiting in the Items tab for the editor to be free (`_failedWrites`).
- Unsaved text in the Alarms tab: a draft without a readable time, or an edit with a time that cannot be read.
- The sound file chooser still open (`SoundSettings`), which saves the file picked after the panel closed.
- The panel's own `Updater`, in a shell without the service, while it checks or updates.

## Considered options

- Keep the panels loaded. It costs about 45 MB on three monitors for a popout that is closed most of the time.
- Load on the first open only, synchronously. It adds the whole load to every first click, 34 to 46 ms warm and 63 to 66 ms cold, where the hover hides most of it.
- Load and unload with the open, with no idle time. It adds the load to every open, and a panel closed with an untitled draft or a failed write would lose it.
- Keep the panel and unload only the tabs. The compiled type and the `KeyboardPanel` stay, and every tab needs the same rules for what holds it.

## Consequences

- Measured offscreen with the service over a copy of the same database, 20 s after the start, three readings each: on three monitors 130.6 MB of RSS and 30.5 MB anonymous, against 175.8 MB and 71.7 MB before; on one monitor 130.8 MB and 30.8 MB, against 155.2 MB and 51.3 MB. The plugin now costs about 14 MB of RSS over the shell whatever the number of monitors.
- Unloading gives back much less than never loading. With every panel opened, closed and unloaded, the same shell on three monitors used 168.9 MB of RSS (161.8 to 173.3), against 179.7 MB before with the panels loaded. The freed memory stays with the process for the next load; a call to `gc()` after the unload changed nothing. The saving is for the monitors whose panel is never opened.
- The load moves to the first open. Measured offscreen: a hover loads the panel in the background in 25 to 34 ms warm and 54 to 59 ms cold, before a click can come. An open with no hover, from the IPC or a hotkey, now takes 34 to 46 ms warm and 63 to 66 ms cold, where it took 0 to 4 ms with the panel always loaded. Cold is the first load of the shell, which also compiles `Panel.qml`.
- A panel loaded again starts on the Items tab, as every open does. The Items tab takes the filter and the search from the widget's `ItemsDb`, which keeps them (ADR-0018), and selects the first row, since no `itemsUpdated` comes for rows the `ItemsDb` already had (`adoptDb` in `ui/ItemsTab.qml`). The row that was selected, the scroll position and the Settings page shown are not kept.
- Offscreen, a widget at the top left corner of its window is under the pointer from the start (`tooltipHovered` read true in `test/alarm.sh`, and in `test/startup.sh` all three panels loaded), so it loads its panel. The QML scripts place the widget away from that corner. `test/panel.sh` drives the hover and the click with `QtTest`'s `TestEvent`, and shortens `panelIdleMs`.

## Gates

Each gate failed with its defect planted and passes without it.

- No panel exists after the start: `test/startup.sh` with three widgets and the service, and `test/panel.sh`, where the list IPC and a `close` load none. They failed with `panelWanted` true at the start.
- The hover loads the panel without opening it, and a click then opens it on the Items tab with its rows (`test/panel.sh`). It failed with the hover handler removed.
- A click in the same turn as the hover, before the background load ends, opens the panel with its rows. It failed when `open()` left `asynchronous` on.
- An IPC `open` with no hover loads and opens the panel. It failed with the `open()` of before, which did nothing without a panel.
- Closed and idle, the panel is unloaded and its instance destroyed. The pointer back on the icon keeps it. A panel loaded again shows the Items tab, a row written while it was unloaded selected first, and the filter and search it had. They failed with the timer's unload removed, and with `adoptDb` removed.
- An untitled draft, an edit whose write failed, and a write in flight each keep the closed panel loaded past the idle time (`test/panel.sh`), and so does an alarm draft without a readable time (`test/alarm.sh`). They failed with each rule of `busy()` or the check of `db.writing` removed.
- `test/render.sh` draws the same pictures as before: 13 of 20 shots are the same bytes, and the other 7 differ from `main` as much as two runs of `main` differ from each other.
