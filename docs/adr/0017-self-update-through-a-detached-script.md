# Update the plugin through a detached script and a state file

The Updates page pulls new commits of `origin/main` into the plugin folder. The shell's plugin watcher answers any write in that folder with a global reload about 150 ms later, and the reload destroys the service, every panel and every `Process` they own, sometimes in two bursts. Nothing that starts the update from inside the plugin survives to report its result, and the host gives a plugin no reload hook, no path and no update helper.

`data/update.sh` does all of the git work and has three modes. `status` prints the checkout as `key value` lines and touches nothing. `check` fetches `origin/main` and records what is new. `apply` fetches, refuses anything that could lose work, extracts `origin/main` into a temporary folder outside the plugin folder, runs `omarchy-plugin-validate` there, and only then fast-forwards `main` to the commit it validated and sends a notification. The shell's plugin watcher sees the merge and reloads the plugin; the script never asks for a reload. Both write the state file `${XDG_STATE_HOME:-~/.local/state}/omanotes/update`, whole, through a temporary file and a move. `data/Updater.qml` starts `apply` in its own `systemd-run --user` unit, outside the shell's process tree, and every Updater reads the state file, so the panel that comes back after the reload shows the result. `data/Update.js` turns the status lines and the state file into the one view the page draws.

## Considered options

- `omarchy plugin update othavi0.omanotes --yes`. It fetches `origin HEAD` rather than `main`, finds local changes only when the merge fails, leaves its result on stderr only, and a `Process` running it dies with the reload.
- A lock file or a result file inside the plugin folder. Any write there that is not under `.git` reloads the shell.

## Consequences

- Apply refuses before it touches the tree, and records why: local changes (`dirty`), a branch other than `main` (`offMain`), local commits that `origin/main` lacks (`diverged`), untracked files that `origin/main` tracks and the merge would refuse to overwrite (`untracked`), a folder that is not the top of its own work tree (`notGit`, so an update never pulls a parent repository) and no `origin` (`noOrigin`). A fetch that fails is `offline`.
- A version that does not validate is recorded as `invalid` and never reaches the plugin folder: nothing there is written, so the shell does not reload and there is nothing to roll back. The host's own updater merges first and resets on a failed validation; a reset that fails, for instance on a lock another git holds, leaves a folder that the shell loads anyway.
- A merge that git refuses after all is `mergeFailed`, with git's first error line. `diverged` means only local commits.
- The script exports `GIT_OPTIONAL_LOCKS=0`, so `status`, which several panels run at any moment, never takes `index.lock` from under the merge. `test/update.sh` runs eight applies against four `status` loops.
- The state file keeps whole hashes, so two runs never compare abbreviations of different lengths. The page shortens them.
- ssh runs with `-oBatchMode=yes` on top of the user's ssh command, since the unit has no terminal to answer a prompt.
- The script exits 0 once it recorded a result, a refusal included, 3 when the lock stayed taken for a minute and 1 when it could record nothing.
- The script is `main "$@"; exit $?` on one line, so bash has read all of it before the merge replaces it. `test/update.sh` proves an update that rewrites the script itself.
- `flock` on `update.lock` beside the state file serializes the service's daily check, a click in any panel and an apply. Each waits up to a minute for it. Every command the script starts runs with the lock's descriptor closed, so a `git gc` that git detaches never keeps the lock.
- A check that cannot reach origin records `offline` and keeps what the last fetch put in `origin/main`. A check that finds nothing new after an update keeps the `updated` record, so the result of an update is not replaced by the check queued behind it.
- A check result counts only against the HEAD it was made on, so any later pull, ours or the host's, clears the dot. An `updating` record older than five minutes reads as stopped.
- The service keeps the only Updater that checks by itself, once a day, when Check daily is on, so several monitors never mean several fetches. Without a service a manual check still works. A test drives the service's clock and never fetches.
- Update is off while an alarm rings, because the reload would drop the ring.
- The panel closes with the reload, so the notification is what the user sees at once. The Updates page shows the result when the panel opens again.
