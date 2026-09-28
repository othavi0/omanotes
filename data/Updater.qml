import QtQuick
import Quickshell
import Quickshell.Io
import "Update.js" as Update

// The Updates section's model: runs data/update.sh and reads the state
// file it leaves (ADR-0017). The panel keeps one for its dot and its page;
// the service keeps the only one that checks daily, so several monitors
// never mean several fetches. Every Updater reads the same file, which is
// the bus for update results as the database is for rows.
QtObject {
    id: root

    // Tests point these at a throwaway clone and run apply directly.
    property string pluginDir: String(Qt.resolvedUrl("..")).replace(/^file:\/\//, "").replace(/\/$/, "")
    readonly property string scriptPath: String(Qt.resolvedUrl("update.sh")).replace(/^file:\/\//, "")
    property var launcher: ["systemd-run", "--user", "--collect", "--quiet", "-p", "RuntimeMaxSec=180"]
    property bool daily: false
    property bool checkUpdates: true            // the setting, bound by the owner
    property double nowMs: Date.now()

    readonly property string stateDir: {
        var xdg = Quickshell.env("XDG_STATE_HOME")
        return (xdg && String(xdg) !== "" ? String(xdg) : String(Quickshell.env("HOME")) + "/.local/state") + "/omanotes"
    }
    property var local: null
    property var state: null
    readonly property var view: Update.view(root.local, root.state, root.checkProcess.running, root.nowMs)
    readonly property bool showDot: root.checkUpdates && Update.hasUpdate(root.local, root.state)

    // Reads the checkout and the state file again.
    function refresh() {
        root.stateFile.reload()
        if (!root.statusProcess.running) root.statusProcess.running = true
    }

    function check() {
        if (root.checkProcess.running || !root.view.canCheck) return
        root.checkProcess.running = true
    }

    // Runs apply outside the shell's process tree: the merge reloads the
    // shell, which destroys this object and anything it started. The new
    // panel reads the result from the state file.
    function apply() {
        if (!root.view.canUpdate) return
        Quickshell.execDetached(Update.applyCommand(root.launcher, "omanotes-update-" + Date.now(),
            { PATH: Quickshell.env("PATH"), XDG_STATE_HOME: Quickshell.env("XDG_STATE_HOME") }, root.scriptPath, root.pluginDir))
    }

    property Process statusProcess: Process {
        command: ["bash", root.scriptPath, "status", root.pluginDir]
        stdout: StdioCollector { id: statusOut; waitForEnd: true }
        onExited: root.local = Update.parseLocal(statusOut.text)
    }

    property Process checkProcess: Process {
        command: ["bash", root.scriptPath, "check", root.pluginDir]
        onExited: root.refresh()
    }

    // The script replaces the file whole, so a missing or replaced file is
    // also read again on the minute tick.
    property FileView stateFile: FileView {
        path: root.stateDir + "/update"
        watchChanges: true
        printErrors: false
        onFileChanged: root.refresh()
        onLoaded: root.state = Update.parseState(root.stateFile.text())
        onLoadFailed: root.state = null
    }

    property Timer minute: Timer {
        interval: 60000
        repeat: true
        running: true
        onTriggered: {
            root.nowMs = Date.now()
            root.stateFile.reload()
        }
    }

    // First look a minute after start-up, then hourly; dueForCheck keeps it
    // to one fetch a day.
    property Timer dailyCheck: Timer {
        interval: 60000
        repeat: true
        running: root.daily
        onTriggered: {
            interval = 3600000
            if (Update.dueForCheck(root.local, root.state, Date.now())) root.check()
        }
    }

    Component.onCompleted: root.refresh()
}
