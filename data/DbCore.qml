import QtQuick
import Quickshell
import Quickshell.Io
import "Db.js" as Db

// What every database object shares: the file, start-up with the migration
// race (ADR-0011), one write queue with a single sqlite3 Process, and the
// watcher that asks for a reload (ADR-0004). ItemsDb and AlarmsDb build on it
// and read their own tables, each read in its own Process.
QtObject {
    id: root

    // $XDG_DATA_HOME/omarchy, falling back to ~/.local/share/omarchy.
    readonly property string dataDir: {
        var xdg = Quickshell.env("XDG_DATA_HOME")
        if (xdg && String(xdg) !== "") return String(xdg) + "/omarchy"
        return String(Quickshell.env("HOME")) + "/.local/share/omarchy"
    }
    readonly property string dbPath: root.dataDir + "/scratchpad.db"

    property bool ready: false                 // init() completed

    signal failed(string message)
    // Start-up finished, the file changed or a write asked for it: the store
    // on top reads its tables again.
    signal reloadDue()
    signal writeEnded(string kind, var args, int exitCode, string output, string errors, bool fromScript)
    // A write not queued: not ready, or its SQL could not be built.
    signal writeRefused(string kind, var args, string message)

    // Every failure reaches the journal. `failed` also carries it, except for
    // a write a script made.
    function fail(message, fromScript) {
        root._log(message)
        if (!fromScript && !root._fromScript) root.failed(message)
    }
    function _log(message) {
        console.error("omanotes db: " + message)
        return message
    }

    // The panel answers some signals of ItemsDb as if its user acted. Writes
    // a script makes inside run() reload the views but emit none of them.
    property bool _fromScript: false
    function fromScript(run) {
        root._fromScript = true
        try {
            return run()
        } finally {
            root._fromScript = false
        }
    }

    // What parse makes of a finished read's output, or null once the failure
    // is reported.
    function _parsed(what, exitCode, stdout, stderr, parse) {
        var error
        if (exitCode !== 0) {
            error = Db.errorText(stderr.text, exitCode)
        } else {
            try {
                return parse(stdout.text)
            } catch (e) {
                error = e.message
            }
        }
        root.fail(what + " read failed: " + error)
        return null
    }

    function reloadSoon() {
        reloadDebounce.restart()
    }

    property string _writeKind: ""
    property var _writeArgs: null
    property bool _writeFromScript: false
    property var _writeQueue: []

    property Process writeProcess: Process {
        stdout: StdioCollector {
            id: writeStdout
            waitForEnd: true
        }
        stderr: StdioCollector {
            id: writeStderr
            waitForEnd: true
        }
        onExited: function(exitCode) {
            var kind = root._writeKind
            var args = root._writeArgs
            var fromScript = root._writeFromScript
            root._writeKind = ""
            root._writeArgs = null
            root._writeFromScript = false
            Qt.callLater(root._runNextWrite)
            if (kind === "init" || kind === "migrate") root._startupEnded(kind, exitCode)
            else root.writeEnded(kind, args, exitCode, writeStdout.text, writeStderr.text, fromScript)
        }
    }

    function _startupEnded(kind, exitCode) {
        if (exitCode !== 0) {
            if (kind === "migrate" && Db.migrationRaced(writeStderr.text)) {
                root.init()
                return
            }
            root.fail(Db.errorText(writeStderr.text, exitCode))
            initRetry.start()
            return
        }
        if (kind === "init") {
            var version = root._parsed("schema version", exitCode, writeStdout, writeStderr, Db.parseVersion)
            if (version === null) {
                initRetry.start()
                return
            }
            var migration = Db.migrateSql(version)
            if (migration.length > 0) {
                root._enqueue("migrate", Db.sqliteCommand(root.dbPath, migration, false), null)
                return
            }
        }
        root.ready = true
        // (Re)bind the watcher now that the file exists, then load.
        dbFile.reload()
        root.reloadDue()
    }

    // One sqlite3 process at a time; later writes wait their turn instead of
    // being dropped.
    function _enqueue(kind, command, args) {
        root._writeQueue.push({ kind: kind, command: command, args: args, fromScript: root._fromScript })
        root._runNextWrite()
    }
    function _runNextWrite() {
        if (root.writeProcess.running || root._writeQueue.length === 0) return
        var next = root._writeQueue.shift()
        root._writeKind = next.kind
        root._writeArgs = next.args
        root._writeFromScript = next.fromScript
        root.writeProcess.command = next.command
        root.writeProcess.running = true
    }
    // Returns why the write was refused, or "" once it is queued. build()
    // throws on an invalid value, before any SQL exists.
    function _write(kind, build, args) {
        if (!root.ready) return root._refused(kind, args, "not ready")
        var sql
        try {
            sql = build()
        } catch (e) {
            return root._refused(kind, args, e.message)
        }
        root._enqueue(kind, Db.sqliteCommand(root.dbPath, sql, false), args)
        return ""
    }
    function _refused(kind, args, message) {
        root.writeRefused(kind, args, message)
        return message
    }

    // Any change to the file, an outside edit or a write of this object,
    // triggers a debounced reload. QtObject has no default property, so the
    // watcher and the timers are explicit properties.
    property FileView dbFile: FileView {
        path: root.dbPath
        watchChanges: true
        printErrors: false
        onFileChanged: {
            if (!root.ready) return
            reloadDebounce.restart()
        }
    }

    property Timer reloadDebounce: Timer {
        interval: 80
        repeat: false
        onTriggered: root.reloadDue()
    }

    property Timer initRetry: Timer {
        interval: 500
        repeat: false
        onTriggered: {
            interval = Math.min(interval * 2, 30000)
            root.init()
        }
    }

    // Create the data dir, read the schema version and migrate from it
    // (ADR-0011). Retries until it succeeds.
    function init() {
        if (root.ready || root._writeKind === "init" || root._writeKind === "migrate") return
        root._enqueue("init", Db.initCommand(root.dataDir, root.dbPath), null)
    }
}
