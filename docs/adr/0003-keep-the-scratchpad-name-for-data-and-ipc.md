# Keep the scratchpad name for the database and the IPC target

Omanotes started as a copy of omatodolist, which stored everything in `scratchpad.db` and registered the IPC target `scratchpad`. Omanotes keeps both (`$XDG_DATA_HOME/omarchy/scratchpad.db` in `data/Db.qml`, `IpcHandler { target: "scratchpad" }` in `BarWidget.qml` and `ipcTarget: "scratchpad"` in `Panel.qml`) so notes already written and scripts already calling the target keep working after the switch.

## Consequences

- The name belongs only to the database file and the IPC target. Everything else calls the product and the data layer Omanotes, including code comments and the `omanotes db:` log prefix.
- Omanotes and omatodolist cannot be enabled together: they would register the same IPC target and write the same database.
