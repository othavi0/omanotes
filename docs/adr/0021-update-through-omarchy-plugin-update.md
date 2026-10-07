# Update through `omarchy plugin update`

The plugin no longer updates itself. ADR-0017 had the Updates page fetch `origin/main`, validate it in a copy, fast-forward the plugin folder and restart the shell, with a daily check that marked the gear with a dot. The Omarchy plugin marketplace blocks that pattern. A plugin that replaces its reviewed code with the mutable head of its upstream and restarts the shell was refused in issue #4979 (othavi0.agent-bar: "replacing reviewed executable code with mutable remote HEAD") and #5338, and #6753 (hyprmoncfg) was approved only after its panel self-updater was removed. The marketplace approves a plugin at one exact commit, so code that pulls past that commit undoes the review.

The update now goes through Omarchy. The Updates page shows the version of the code that runs and the two commands the user runs in a terminal:

```
omarchy plugin update othavi0.omanotes
omarchy restart shell
```

Copy puts only the first command on the clipboard. `omarchy-plugin-update` exits 0 when the plugin is already up to date ("is up to date.") and when the user answers no to its prompt ("Skipped"), so `update && restart` would restart the shell with nothing new and stop an alarm that rings. The page says in words that `omarchy restart shell` comes after the update prints "Updated othavi0.omanotes.". Copy runs `/usr/bin/wl-copy` with the command on its stdin and only `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` in its environment, the way the shell's own panels copy; `Quickshell.clipboardText` takes on Wayland only while one of the shell's windows has the keyboard. The toast says Copied only when wl-copy exits 0, and shows its error otherwise. The commands live in `ui/Settings.js`, and `test/settings-text.test.mjs` holds the id in them to the id of `manifest.json`.

`omarchy plugin update` without `--yes` prints the diff, asks before it pulls, fast-forwards the folder, runs `omarchy-plugin-validate` and resets the folder when the new version does not validate. It does not restart the shell. The restart stays a separate command because the reload the shell does after a change in the plugin folder keeps the components it already compiled, as ADR-0017 measured, so only a restart loads the new code and runs a new migration.

## Considered options

- Keep the self-update and turn it off by default. The code stays in the reviewed tree, and the reviewer still has to accept a path that replaces it.
- Run `omarchy plugin update othavi0.omanotes --yes` from the page. It is the same pattern #4979 refused: an update with no review by the user, started from inside the plugin.
- Keep the daily check without the apply. It still fetches the upstream from inside the shell, and the dot it shows only points at the commands this page shows anyway.

## Consequences

- The plugin starts no network access and hands no web address to a browser: the Updates page has no link to the listing, which exists only once the marketplace approves the plugin. `data/update.sh`, `data/Update.js`, `data/Updater.qml`, the gear's dot, the Check daily switch and their tests are gone. The marketplace scanner no longer finds `systemd-run` in the plugin, so the `service-management` capability no longer applies.
- The page and the header show `VERSION` from `ui/Settings.js`, and `test/settings-text.test.mjs` holds it equal to the version of `manifest.json`. It ships with the code, so between `omarchy plugin update` and the restart the page names the version that runs, not the one on disk.
- The `check_updates` column stays in the `settings` table, because the schema lives in `db/`, but `Db.SETTINGS` no longer has the key. The cells the binary is held to in `test/fixtures/parity/cells.json` still carry it, and `test/bin-cells.test.mjs` compares the frozen parse on the keys of `Db.SETTINGS` only. A later schema step can drop the column together with the fixture.
- Nothing runs the new binary before it reaches the plugin folder. The self-update ran `selftest` on the binary it would merge (ADR-0018); `omarchy plugin update` validates the manifest and the files and runs no binary. What holds a committed binary to `db/` now is `tools/verify-bin.sh --check` in `npm test` and the CI that rebuilds both binaries and compares their bytes (PR #70).
- The user sees a new version only by running the command. The marketplace marks a commit published after the approved one as an unverified update until a maintainer verifies it.
