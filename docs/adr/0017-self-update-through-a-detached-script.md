# Update the plugin through a detached script and a state file

The Updates page pulls new commits of `origin/main` into the plugin folder. The shell's plugin watcher answers any write in that folder with a global reload about 150 ms later, and the reload destroys the service, every panel and every `Process` they own, sometimes in two bursts. Nothing that starts the update from inside the plugin survives to report its result, and the host gives a plugin no reload hook, no path and no update helper.

`data/update.sh` does all of the git work and has three modes. `status` prints the checkout as `key value` lines and touches nothing. `check` fetches `origin/main` and records what is new. `apply` fetches, refuses anything that could lose work, fast-forwards `main`, runs `omarchy-plugin-validate`, asks the shell to rescan and sends a notification. Both write the state file `${XDG_STATE_HOME:-~/.local/state}/omanotes/update`, whole, through a temporary file and a move. `data/Updater.qml` starts `apply` in its own `systemd-run --user` unit, outside the shell's process tree, and every Updater reads the state file, so the panel that comes back after the reload shows the result. `data/Update.js` turns the status lines and the state file into the one view the page draws.

## Considered options

- `omarchy plugin update othavi0.omanotes --yes`. It fetches `origin HEAD` rather than `main`, finds local changes only when the merge fails, leaves its result on stderr only, and a `Process` running it dies with the reload.
- A lock file or a result file inside the plugin folder. Any write there that is not under `.git` reloads the shell.

## Consequences

- Apply refuses before it touches the tree, and records why: local changes (`dirty`), a branch other than `main` (`offMain`), local commits that `origin/main` lacks (`diverged`), a folder that is not the top of its own work tree (`notGit`, so an update never pulls a parent repository) and no `origin` (`noOrigin`). A fetch that fails is `offline`.
- A merge that does not validate is rolled back with `git reset --hard ORIG_HEAD`, as the host's updater does, and recorded as `invalid`. The shell reloads once for the merge and once for the rollback.
- The script is `main "$@"; exit $?` on one line, so bash has read all of it before the merge replaces it. `test/update.sh` proves an update that rewrites the script itself.
- `flock` on `update.lock` beside the state file serializes the service's daily check, a click in any panel and an apply. A check waits for it; a second apply leaves at once and writes nothing.
- A check result counts only against the HEAD it was made on, so any later pull, ours or the host's, clears the dot. An `updating` record older than five minutes reads as stopped.
- The service keeps the only Updater that checks by itself, once a day, when Check daily is on, so several monitors never mean several fetches. Without a service a manual check still works. A test drives the service's clock and never fetches.
- Update is off while an alarm rings, because the reload would drop the ring.
- The panel closes with the reload, so the notification is what the user sees at once. The Updates page shows the result when the panel opens again.
