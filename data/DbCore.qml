import QtQuick
import Quickshell
import Quickshell.Io
import "Db.js" as Db

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

    // The settings row, every Db reading it through the watcher (ADR-0016).
    // Fallbacks until the first read lands. Only ItemsDb writes it.
    property var settings: Db.parseSettings("").settings
    // What each setting takes, for the controls that edit it.
    readonly property var settingsSpec: Db.SETTINGS
    property bool settingsLoaded: false
    property real dbBytes: 0

    signal failed(string message)
    signal reloadDue()
    signal writeEnded(string kind, var args, int exitCode, string output, string errors, bool fromScript)
    signal writeRefused(string kind, var args, string message)

    function fail(message, fromScript) {
        root._log(message)
        if (!fromScript && !root._fromScript) root.failed(message)
    }
    function _log(message) {
        console.error("omanotes db: " + message)
        return message
    }

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
        root._reload()
    }

    function _reload() {
        root._listSettings()
        root.reloadDue()
    }

    // The overlay of settings writes still on their way: ItemsDb lays each
    // patch over the row at once, and a read drops a key's overlay once it
    // started after that write ended.
    property var _settingsRow: null
    property var _settingsPatch: ({})
    property int _settingsSeq: 0
    property int _settingsDoneSeq: 0
    property int _settingsReadSeq: 0      // _settingsDoneSeq when the running read started
    property bool _settingsStale: false

    function _showSettings() {
        var values = {}
        for (var key in root._settingsPatch) values[key] = root._settingsPatch[key].value
        root.settings = Db.mergeSettings(root._settingsRow ? root._settingsRow.settings : Db.parseSettings("").settings, values)
    }

    function _listSettings() {
        if (!root.ready) return
        if (root.settingsProcess.running) { root._settingsStale = true; return }
        root._settingsStale = false
        root._settingsReadSeq = root._settingsDoneSeq
        root.settingsProcess.command = Db.sqliteCommand(root.dbPath, Db.settingsSql(), true)
        root.settingsProcess.running = true
    }

    property Process settingsProcess: Process {
        stdout: StdioCollector {
            id: settingsStdout
            waitForEnd: true
        }
        stderr: StdioCollector {
            id: settingsStderr
            waitForEnd: true
        }
        onExited: function(exitCode) {
            var read = root._parsed("settings", exitCode, settingsStdout, settingsStderr, Db.parseSettings)
            if (root._settingsStale) {
                Qt.callLater(root._listSettings)
                return
            }
            if (read === null) return
            root._settingsRow = read
            for (var key in root._settingsPatch) {
                if (root._settingsPatch[key].seq <= root._settingsReadSeq) delete root._settingsPatch[key]
            }
            root._showSettings()
            root.dbBytes = read.bytes
            root.settingsLoaded = true
        }
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
    // Returns why the write was refused, or "" once it is queued.
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

    // QtObject has no default property, so the watcher and the timers are
    // explicit properties.
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
        onTriggered: root._reload()
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
