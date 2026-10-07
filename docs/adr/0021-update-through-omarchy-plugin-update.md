# Update through `omarchy plugin update`

The plugin no longer updates itself. ADR-0017 had the Updates page fetch `origin/main`, validate it in a copy, fast-forward the plugin folder and restart the shell, with a daily check that marked the gear with a dot. The Omarchy plugin marketplace blocks that pattern. A plugin that replaces its reviewed code with the mutable head of its upstream and restarts the shell was refused in issue #4979 (othavi0.agent-bar: "replacing reviewed executable code with mutable remote HEAD") and #5338, and #6753 (hyprmoncfg) was approved only after its panel self-updater was removed. The marketplace approves a plugin at one exact commit, so code that pulls past that commit undoes the review.

The update now goes through Omarchy. The Updates page shows the version that `manifest.json` names and the two commands the user runs in a terminal:

```
omarchy plugin update othavi0.omanotes
omarchy restart shell
```

Copy puts both on the clipboard as one line joined by `&&`, so an update that fails does not restart the shell. Open shows the plugin's listing, `https://omarchyplugins.com/plugin.html?id=othavi0.omanotes`, in the browser. The commands and the URL live in `ui/Settings.js`, and `test/settings-text.test.mjs` holds the id in them to the id of `manifest.json`.

`omarchy plugin update` without `--yes` prints the diff, asks before it pulls, fast-forwards the folder, runs `omarchy-plugin-validate` and resets the folder when the new version does not validate. It does not restart the shell. The restart stays a separate command because the reload the shell does after a change in the plugin folder keeps the components it already compiled, as ADR-0017 measured, so only a restart loads the new code and runs a new migration.

## Considered options

- Keep the self-update and turn it off by default. The code stays in the reviewed tree, and the reviewer still has to accept a path that replaces it.
- Run `omarchy plugin update othavi0.omanotes --yes` from the page. It is the same pattern #4979 refused: an update with no review by the user, started from inside the plugin.
- Keep the daily check without the apply. It still fetches the upstream from inside the shell, and the dot it shows only points at the commands this page shows anyway.

## Consequences

- The plugin starts no network access. `data/update.sh`, `data/Update.js`, `data/Updater.qml`, the gear's dot, the Check daily switch and their tests are gone. The marketplace scanner no longer finds `systemd-run` in the plugin, so the `service-management` capability no longer applies.
- The page reads `manifest.json` through a `FileView` in `ui/SettingsTab.qml`, which hands the version to the page and to the header.
- The `check_updates` column stays in the `settings` table, and `Db.SETTINGS` still reads it, because the schema lives in `db/` and the cells the binary is held to in `test/fixtures/parity/cells.json` carry it. Nothing reads its value. A later schema step can drop it together with the fixture.
- The user sees a new version only by running the command or by visiting the listing. The marketplace marks a commit published after the approved one as an unverified update until a maintainer verifies it.
