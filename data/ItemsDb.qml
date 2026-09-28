import QtQuick
import Quickshell.Io
import "Db.js" as Db

DbCore {
    id: root

    // Cached rows (populated by reads; the UI binds to these).
    property var items: []                     // list() results
    // Every item, whatever list() last filtered: the IPC reads this, and the
    // panel sharing this Db narrows `items`.
    property var allItems: []
    property bool allItemsLoaded: false
    property var history: []                   // historyList() results
    property int unreadNotes: 0                // notes with status 0
    property int pendingTodos: 0               // todos with status 0
    property int totalNotes: 0                 // all notes, unfiltered
    property int totalTodos: 0                 // all todos, unfiltered
    property int totalHistory: 0               // all history, past historyList()'s limit

    // Last list() filter, remembered so load() can re-fetch the same subset
    // after a change.
    property string listFilter: "all"
    property string listQuery: ""

    // A read asked for while its Process runs is marked stale and re-runs when
    // that Process ends, failed or not, so the last reload always lands.
    property bool _countsStale: false
    property bool _listStale: false
    property bool _allItemsStale: false
    property bool _historyStale: false

    // The panel answers added, statusChanged, itemDeleted, historyCleared and
    // failed as if its user acted: it moves the selection, which commits the
    // open edit, and shows a toast. It answers writeFailed by giving the text
    // back to the editor.
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
    // Follows failed for a write, with what the write carried, so the editor
    // can take back the text of its own add or update.
    signal writeFailed(string kind, var args, string message)

    function _failWrite(kind, args, message, fromScript) {
        root.fail(message, fromScript)
        if (!fromScript && !root._fromScript) root.writeFailed(kind, args, message)
        return message
    }
    function _refuse(message) {
        root.fail(message)
        return message
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
            if (root._countsStale) {
                Qt.callLater(root.loadCounts)
                return
            }
            if (c === null) return
            root.unreadNotes = c.unreadNotes
            root.pendingTodos = c.pendingTodos
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
            if (root._listStale) {
                Qt.callLater(function() { root.list(root.listFilter, root.listQuery) })
                return
            }
            if (rows === null) return
            root.items = rows
            if (root.allItemsProcess.running || root._allItemsStale) root._itemsUpdateHeld = true
            else root.itemsUpdated(rows)
        }
    }

    // itemsUpdated waits for the allItems read of the same reload, so the
    // panel never judges a row missing from a filtered list against allItems
    // from before the change.
    property bool _itemsUpdateHeld: false
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
            if (root._allItemsStale) {
                Qt.callLater(root.listAll)
                return
            }
            if (rows !== null) {
                root.allItems = rows
                root.allItemsLoaded = true
            }
            if (!root._itemsUpdateHeld) return
            root._itemsUpdateHeld = false
            root.itemsUpdated(root.items)
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
            if (root._historyStale) {
                Qt.callLater(root.historyList)
                return
            }
            if (rows === null) return
            root.history = rows
            root.historyUpdated(rows)
        }
    }

    // Writes whose SQL prints Db.CHANGES.
    readonly property var _oneItemWrites: ["setStatus", "update", "convertType", "deleteItem", "move"]

    onReloadDue: root.load()
    onWriteRefused: function(kind, args, message) { root._failWrite(kind, args, message, false) }
    onWriteEnded: function(kind, args, exitCode, output, errors, fromScript) {
        if (exitCode !== 0) {
            root._failWrite(kind, args, Db.errorText(errors, exitCode), fromScript)
            root.reloadSoon()
            return
        }
        if (root._oneItemWrites.indexOf(kind) >= 0 && !Db.parseFound(output)) {
            root._failWrite(kind, args, "item not found", fromScript)
            root.reloadSoon()
            return
        }
        if (!fromScript) {
            if (kind === "add") root.added(Db.parseId(output), args.type, args.title)
            else if (kind === "setStatus") root.statusChanged(args.id, args.status)
            else if (kind === "update") root.updated(args.id, args.title)
            else if (kind === "convertType") root.typeChanged(args.id)
            else if (kind === "deleteItem") root.itemDeleted(args.id)
            else if (kind === "deleteHistory") root.historyRowDeleted(args.id)
            else if (kind === "clearHistory") root.historyCleared()
        }
        // The watcher sees this write too; both land on one timer, so the
        // write reloads once even if the watcher misses it.
        root.reloadSoon()
    }

    function loadCounts() {
        if (!root.ready) return
        if (root.countsProcess.running) { root._countsStale = true; return }
        root._countsStale = false
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
        if (!root.ready) return
        if (root.historyProcess.running) { root._historyStale = true; return }
        root._historyStale = false
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

    // Puts the item just before `anchorId`, or just after it when `after`,
    // inside its block. The list shows the move before the reload confirms it.
    function move(id, anchorId, after) {
        var error = root._write("move", function() { return Db.moveSql(id, anchorId, after) },
            { id: Number(id), anchorId: Number(anchorId), after: !!after })
        if (error === "") root.items = Db.movedRows(root.items, id, anchorId, after)
        return error
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
