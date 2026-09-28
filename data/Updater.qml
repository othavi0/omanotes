import QtQuick
import Quickshell
import Quickshell.Io
import "Update.js" as Update

// The Updates section's model: runs data/update.sh and reads the state
// file it leaves (ADR-0017). The service owns the one Updater of the shell
// and checks daily through it; a panel without the service makes its own.
// Every Updater reads the same file, which is the bus for update results as
// the database is for rows.
QtObject {
    id: root

    // Tests point these at a throwaway clone and run apply directly.
    property string pluginDir: String(Qt.resolvedUrl("..")).replace(/^file:\/\//, "").replace(/\/$/, "")
    readonly property string scriptPath: String(Qt.resolvedUrl("update.sh")).replace(/^file:\/\//, "")
    property var launcher: ["systemd-run", "--user", "--collect", "--quiet", "-p", "RuntimeMaxSec=180"]
    property bool daily: false
    property bool checkUpdates: true            // the setting, bound by the owner
    // True while the reload an update sets off would drop something: the
    // service binds it to the ring.
    property bool blocked: false
    // Longer than a check holds the lock (a 20 s fetch), so an apply queued
    // behind one is not called lost.
    property int startTimeoutMs: 30000
    property double nowMs: Date.now()

    readonly property string stateDir: {
        var xdg = Quickshell.env("XDG_STATE_HOME")
        return (xdg && String(xdg) !== "" ? String(xdg) : String(Quickshell.env("HOME")) + "/.local/state") + "/omanotes"
    }
    property var local: null
    property var state: null
    // { at, caller } from apply() until the script's record shows up.
    property var requested: null
    readonly property var view: Update.view(root.local, root.state, root.checkProcess.running, root.requested !== null, root.nowMs)
    readonly property bool showDot: root.checkUpdates && root.view.phase === "available"

    // A check or an apply that ended without a record, for the caller's
    // toast.
    signal failed(string message, var caller)

    // Reads the checkout and the state file again.
    function refresh() {
        root.stateFile.reload()
        if (!root.statusProcess.running) root.statusProcess.running = true
    }

    function check(caller) {
        if (root.checkProcess.running || !root.view.canCheck) return
        root._checkCaller = caller || null
        root.checkProcess.running = true
    }

    // Runs apply outside the shell's process tree: the merge reloads the
    // shell, which destroys this object and anything it started. The new
    // panel reads the result from the state file. "" once asked for, or why
    // not.
    function apply(caller) {
        if (root.blocked) return "An alarm is ringing"
        if (!root.view.canUpdate) return "Nothing to update"
        root.requested = { at: Date.now(), caller: caller || null }
        root.applyProcess.command = Update.applyCommand(root.launcher, "omanotes-update-" + Date.now(),
            function(key) { return Quickshell.env(key) }, root.scriptPath, root.pluginDir)
        root.applyProcess.running = true
        root.startTimer.restart()
        return ""
    }

    // The daily check, on the minute. A record older than its due time is
    // checked within a minute of it.
    function tick(nowMs) {
        root.nowMs = nowMs
        if (root.daily && !root.checkProcess.running && Update.dueForCheck(root.local, root.state, nowMs)) root.check()
    }

    function _fail(message, caller) {
        console.warn("omanotes update: " + message)
        root.failed(message, caller)
    }

    // The script exits 0 once it recorded a result; anything else left no
    // record for the page to show.
    function _exitText(exitCode, stderr) {
        if (exitCode === 3) return "another check or update held the lock for a minute"
        var line = String(stderr || "").trim().split("\n")[0]
        return line !== "" ? line : "exit " + exitCode
    }

    property var _checkCaller: null
    property Process statusProcess: Process {
        command: ["bash", root.scriptPath, "status", root.pluginDir]
        stdout: StdioCollector { id: statusOut; waitForEnd: true }
        onExited: root.local = Update.parseLocal(statusOut.text)
    }

    property Process checkProcess: Process {
        command: ["bash", root.scriptPath, "check", root.pluginDir]
        stderr: StdioCollector { id: checkErr; waitForEnd: true }
        onExited: function(exitCode) {
            if (exitCode !== 0) root._fail("Could not check: " + root._exitText(exitCode, checkErr.text), root._checkCaller)
            root._checkCaller = null
            root.refresh()
        }
    }

    // With systemd-run this ends as soon as the unit is queued; without a
    // launcher it runs the whole apply.
    property Process applyProcess: Process {
        stderr: StdioCollector { id: applyErr; waitForEnd: true }
        onExited: function(exitCode) {
            if (exitCode === 0 || root.requested === null) return
            var caller = root.requested.caller
            root.requested = null
            root._fail("Could not start the update: " + root._exitText(exitCode, applyErr.text), caller)
        }
    }

    property Timer startTimer: Timer {
        interval: root.startTimeoutMs
        onTriggered: {
            if (root.requested === null) return
            var caller = root.requested.caller
            root.requested = null
            root._fail("The update did not start.", caller)
        }
    }

    // The script replaces the file whole, so a missing or replaced file is
    // also read again on the minute. A record made since apply() was asked
    // for ends the request.
    property FileView stateFile: FileView {
        path: root.stateDir + "/update"
        watchChanges: true
        printErrors: false
        onFileChanged: root.refresh()
        onLoaded: {
            root.state = Update.parseState(root.stateFile.text())
            if (root.requested !== null && root.state && root.state.at >= Math.floor(root.requested.at / 1000) * 1000) {
                root.requested = null
                root.startTimer.stop()
            }
        }
        onLoadFailed: root.state = null
    }

    property Timer minute: Timer {
        interval: 60000
        repeat: true
        running: true
        onTriggered: {
            root.stateFile.reload()
            root.tick(Date.now())
        }
    }

    Component.onCompleted: root.refresh()
}
