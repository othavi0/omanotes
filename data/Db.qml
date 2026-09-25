import QtQuick
import Quickshell
import Quickshell.Io
import "Db.js" as Db

// Omanotes data layer: the single entry point for all database access.
// Views call this component's methods instead of building SQL or touching
// sqlite3 directly. Writes are serialized through one Process (one at a
// time); each read (counts/list/all items/history) uses its own dedicated
// Process so they refresh independently.
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

    // Cached rows (populated by reads; the UI binds to these).
    property var items: []                     // list() results
    // Every item, whatever list() last filtered: the IPC reads this, and the
    // panel sharing this Db narrows `items`.
    property var allItems: []
    property bool allItemsLoaded: false
    property var history: []                   // historyList() results
    property int unreadNotes: 0                // notes with status 0
    property int inProgressTodos: 0            // todos with status 0
    property int totalNotes: 0                 // all notes, unfiltered
    property int totalTodos: 0                 // all todos, unfiltered
    property int totalHistory: 0               // all history, past historyList()'s limit

    // Last list() filter, remembered so load() can re-fetch the same subset
    // after a change.
    property string listFilter: "all"
    property string listQuery: ""
    property bool _listStale: false            // a list() arrived while one was running

    signal itemsUpdated(var items)
    signal countsUpdated()
    signal historyUpdated(var history)
    signal added(int id, string type, string title)
    signal statusChanged(int id, int status)
    signal updated(int id, string title)
    signal typeChanged(int id)
    signal itemDeleted(int id)
    signal historyRowDeleted(int id)
    signal historyCleared()
    signal failed(string message)
    // Follows failed for a write, with what the write carried, so the editor
    // can take back the text of its own add or update.
    signal writeFailed(string kind, var args, string message)

    // Central failure path: surfaces in the journal (console.error) so data-layer
    // errors are visible in the shell logs even before the UI handles them.
    function fail(message, fromScript) {
        console.error("omanotes db: " + message)
        if (!fromScript && !root._fromScript) root.failed(message)
    }
    function _failWrite(kind, args, message, fromScript) {
        root.fail(message, fromScript)
        if (!fromScript && !root._fromScript) root.writeFailed(kind, args, message)
        return message
    }

    // The panel answers added, statusChanged, itemDeleted, historyCleared,
    // failed and writeFailed as if its user acted: it moves the selection, which commits the
    // open edit, and shows a toast. Writes a script makes inside run() reload
    // the views but emit none of them.
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

    property Process countsProcess: Process {
        stdout: StdioCollector {
            id: countsStdout
            waitForEnd: true
        }
        stderr: StdioCollector {
            id: countsStderr
            waitForEnd: true
        }
        onExited: function(exitCode) {
            var c = root._parsed("counts", exitCode, countsStdout, countsStderr, Db.parseCounts)
            if (c === null) return
            root.unreadNotes = c.unreadNotes
            root.inProgressTodos = c.inProgressTodos
            root.totalNotes = c.notes
            root.totalTodos = c.todos
            root.totalHistory = c.history
            root.countsUpdated()
        }
    }

    property Process listProcess: Process {
        stdout: StdioCollector {
            id: listStdout
            waitForEnd: true
        }
        stderr: StdioCollector {
            id: listStderr
            waitForEnd: true
        }
        onExited: function(exitCode) {
            var rows = root._parsed("list", exitCode, listStdout, listStderr, Db.parseRows)
            if (rows === null) return
            if (root._listStale) {
                Qt.callLater(function() { root.list(root.listFilter, root.listQuery) })
                return
            }
            root.items = rows
            root.itemsUpdated(rows)
        }
    }

    property bool _allItemsStale: false
    property Process allItemsProcess: Process {
        stdout: StdioCollector {
            id: allItemsStdout
            waitForEnd: true
        }
        stderr: StdioCollector {
            id: allItemsStderr
            waitForEnd: true
        }
        onExited: function(exitCode) {
            var rows = root._parsed("all items", exitCode, allItemsStdout, allItemsStderr, Db.parseRows)
            if (rows === null) return
            if (root._allItemsStale) {
                Qt.callLater(root.listAll)
                return
            }
            root.allItems = rows
            root.allItemsLoaded = true
        }
    }

    property Process historyProcess: Process {
        stdout: StdioCollector {
            id: historyStdout
            waitForEnd: true
        }
        stderr: StdioCollector {
            id: historyStderr
            waitForEnd: true
        }
        onExited: function(exitCode) {
            var rows = root._parsed("history", exitCode, historyStdout, historyStderr, Db.parseRows)
            if (rows === null) return
            root.history = rows
            root.historyUpdated(rows)
        }
    }

    property string _writeKind: ""
    property var _writeArgs: null
    property bool _writeFromScript: false
    property var _writeQueue: []
    // Writes whose SQL prints Db.CHANGES.
    readonly property var _oneItemWrites: ["setStatus", "update", "convertType", "deleteItem"]

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

            if (exitCode !== 0) {
                if (kind === "migrate" && Db.migrationRaced(writeStderr.text)) {
                    root.init()
                    return
                }
                root._failWrite(kind, args, Db.errorText(writeStderr.text, exitCode), fromScript)
                if (kind === "init" || kind === "migrate") initRetry.start()
                else reloadDebounce.restart()
                return
            }

            if (root._oneItemWrites.indexOf(kind) >= 0 && !Db.parseFound(writeStdout.text)) {
                root._failWrite(kind, args, "item not found", fromScript)
                reloadDebounce.restart()
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

            if (kind === "init" || kind === "migrate") {
                root.ready = true
                // (Re)bind the watcher now that the file exists, then load.
                dbFile.reload()
                root.load()
            } else {
                if (!fromScript) {
                    if (kind === "add") root.added(Db.parseId(writeStdout.text), args.type, args.title)
                    else if (kind === "setStatus") root.statusChanged(args.id, args.status)
                    else if (kind === "update") root.updated(args.id, args.title)
                    else if (kind === "convertType") root.typeChanged(args.id)
                    else if (kind === "deleteItem") root.itemDeleted(args.id)
                    else if (kind === "deleteHistory") root.historyRowDeleted(args.id)
                    else if (kind === "clearHistory") root.historyCleared()
                }
                // The watcher sees this write too; both land on one timer, so
                // the write reloads once even if the watcher misses it.
                reloadDebounce.restart()
            }
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
    function _refuse(message) {
        root.fail(message)
        return message
    }
    // Returns why the write was refused, or "" once it is queued. build()
    // throws on an invalid id, before any SQL exists.
    function _write(kind, build, args) {
        if (!root.ready) return root._failWrite(kind, args, "not ready", false)
        var sql
        try {
            sql = build()
        } catch (e) {
            return root._failWrite(kind, args, e.message, false)
        }
        root._enqueue(kind, Db.sqliteCommand(root.dbPath, sql, false), args)
        return ""
    }

    // Watches the db file; any change (external edits or our own writes)
    // triggers a debounced reload. QtObject has no default property, so this
    // is an explicit property (like the Process objects above) rather than an
    // inline child.
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
        onTriggered: root.load()
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

    function loadCounts() {
        if (!root.ready || root.countsProcess.running) return
        root.countsProcess.command = Db.sqliteCommand(root.dbPath, Db.countsSql(), true)
        root.countsProcess.running = true
    }

    // Unified list. filterType: "all"|"note"|"todo"; query: substring of the
    // title or the body.
    function list(filterType, query) {
        root.listFilter = String(filterType || "all")
        root.listQuery = String(query || "")
        if (!root.ready) return
        if (root.listProcess.running) { root._listStale = true; return }
        root._listStale = false
        root.listProcess.command = Db.sqliteCommand(root.dbPath, Db.listSql(filterType, query), true)
        root.listProcess.running = true
    }

    function listAll() {
        if (!root.ready) return
        if (root.allItemsProcess.running) { root._allItemsStale = true; return }
        root._allItemsStale = false
        root.allItemsProcess.command = Db.sqliteCommand(root.dbPath, Db.listSql("all", ""), true)
        root.allItemsProcess.running = true
    }

    function historyList() {
        if (!root.ready || root.historyProcess.running) return
        root.historyProcess.command = Db.sqliteCommand(root.dbPath, Db.historySql(), true)
        root.historyProcess.running = true
    }

    // Re-fetch everything with the last list() filter (used by the watcher,
    // after writes, and as the reopen safety net).
    function load() {
        root.loadCounts()
        root.list(root.listFilter, root.listQuery)
        root.listAll()
        root.historyList()
    }

    function add(type, title, body) {
        var t = String(title || "").trim()
        if (t === "") return root._refuse("add: empty title")
        var ty = type === "todo" ? "todo" : "note"
        return root._write("add", function() { return Db.addSql(ty, t, body) },
            { type: ty, title: t, body: String(body || "") })
    }

    function setStatus(id, status) {
        var s = status === 1 ? 1 : 0
        return root._write("setStatus", function() { return Db.setStatusSql(id, s) },
            { id: Number(id), status: s })
    }

    // Type is fixed on edit — use convertType() to change it.
    function update(id, title, body) {
        var t = String(title || "").trim()
        if (t === "") return root._refuse("update: empty title")
        return root._write("update", function() { return Db.updateSql(id, t, body) },
            { id: Number(id), title: t, body: String(body || "") })
    }

    // Emits typeChanged(id).
    function convertType(id) {
        return root._write("convertType", function() { return Db.convertTypeSql(id) }, { id: Number(id) })
    }

    // Emits itemDeleted(id).
    function deleteItem(id) {
        return root._write("deleteItem", function() { return Db.deleteItemSql(id) }, { id: Number(id) })
    }

    // Emits historyRowDeleted(id).
    function deleteHistory(id) {
        return root._write("deleteHistory", function() { return Db.deleteHistorySql(id) }, { id: Number(id) })
    }

    function clearHistory() {
        return root._write("clearHistory", Db.clearHistorySql, null)
    }
}
