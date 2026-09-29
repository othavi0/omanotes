import QtQuick
import "Db.js" as Db

// One per bar widget: the view of the Store (data/Store.qml) that the
// widget's IPC and its panel share. It keeps what is per monitor: the filter
// and search of the panel, the move the list shows before the write lands,
// the settings overlay and the signals the panel answers. The rows are the
// Store's, shared by reference, so M monitors hold one copy of them.
QtObject {
    id: root

    readonly property string dataDir: Store.dataDir
    readonly property string dbPath: Store.dbPath
    readonly property bool ready: Store.ready
    // A write is queued or running, for the tests.
    readonly property bool writing: Store.writing

    // The list, narrowed by listFilter and listQuery (the UI binds to it).
    property var items: []
    // Every item, whatever list() last filtered: the IPC reads this, and the
    // panel sharing this Db narrows `items`.
    readonly property var allItems: Store.allItems
    readonly property bool allItemsLoaded: Store.ready
    readonly property var history: Store.history          // the newest 500 entries
    readonly property int unreadNotes: Store.counts.unreadNotes
    readonly property int pendingTodos: Store.counts.pendingTodos
    readonly property int totalNotes: Store.counts.notes
    readonly property int totalTodos: Store.counts.todos
    readonly property int totalHistory: Store.counts.history      // past the 500 of `history`
    readonly property real oldestHistory: Store.counts.oldestHistory  // seconds, 0 with none

    // The settings row, every view reading it (ADR-0016), with this view's
    // writes still on their way laid over it. Fallbacks until the first read.
    property var settings: Db.parseSettings(null).settings
    // What each setting takes, for the controls that edit it.
    readonly property var settingsSpec: Db.SETTINGS
    readonly property bool settingsLoaded: Store.ready
    readonly property real dbBytes: Store.dbBytes

    // Last list() filter, remembered so a reload shows the same subset.
    property string listFilter: "all"
    property string listQuery: ""

    // The panel answers added, statusChanged, itemDeleted, historyCleared and
    // failed as if its user acted: it moves the selection, which commits the
    // open edit, and shows a toast. It answers writeFailed by giving the text
    // back to the editor.
    signal failed(string message)
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
    signal backedUp(string name)
    // Follows failed for a write, with what the write carried, so the editor
    // can take back the text of its own add or update.
    signal writeFailed(string kind, var args, string message)

    property string _key: ""
    property bool _moved: false                 // items shows a drop the file has not confirmed
    property bool _heard: false                 // a snapshot has landed since init
    property bool _fromScript: false
    // key -> { value, id }: the settings writes still on their way.
    property var _settingsPatch: ({})

    function init() {
        if (root._key !== "") return
        root._key = Store.attach()
        root._showSettings()
        root._showItems()
    }
    Component.onDestruction: if (root._key !== "") Store.detach(root._key)

    // QtObject has no default property, so the connection is an explicit property.
    property Connections _store: Connections {
        target: Store
        function onSnapshotApplied(changed) { root._landed(changed) }
        function onFailed(message) { root.failed(message) }
    }

    // The signals go out only for what changed, and each at least once: a
    // list rebuilt for nothing cancels the drag in progress.
    function _landed(changed) {
        for (var key in root._settingsPatch) {
            if (root._settingsPatch[key].id <= Store.covered) delete root._settingsPatch[key]
        }
        root._showSettings()
        var shown = root.items
        root._showItems()
        var first = !root._heard
        root._heard = true
        if (changed || first) {
            root.countsUpdated()
            root.historyUpdated(Store.history)
        }
        if (first || !Db.sameRows(shown, root.items)) root.itemsUpdated(root.items)
    }

    function _showSettings() {
        var values = {}
        for (var key in root._settingsPatch) values[key] = root._settingsPatch[key].value
        root.settings = Db.mergeSettings(Store.settings, values)
    }

    // The rows of the list: every item narrowed by type, or the ids the
    // binary matched for this view's search. A search not answered yet keeps
    // the rows shown.
    function _showItems() {
        root._moved = false
        var query = Db.viewQuery(root.listQuery)
        if (query === "") {
            root.items = Db.typeRows(Store.allItems, root.listFilter)
            return
        }
        var match = Store.matches[root._key]
        if (match && match.query === query && match.filter === root.listFilter) root.items = Db.matchedRows(Store.itemsById, match.ids)
    }

    // The IPC writes inside fromScript: the write reloads the panel but emits
    // none of the signals the panel answers as its user's action (ADR-0004).
    function fromScript(run) {
        root._fromScript = true
        try {
            return run()
        } finally {
            root._fromScript = false
        }
    }

    function fail(message) {
        root._log(message)
        if (!root._fromScript) root.failed(message)
        return message
    }
    function _log(message) {
        console.error("omanotes db: " + message)
        return message
    }

    // Re-fetch everything with the last list() filter (used by the panel as
    // the reopen safety net).
    function load() {
        Store.reload()
    }

    // Unified list. filterType: "all"|"note"|"todo"; query: substring of the
    // title or the body. A type filter alone is answered from the rows this
    // view has, with no spawn; a search rides the next request.
    function list(filterType, query) {
        root.listFilter = String(filterType || "all")
        root.listQuery = String(query || "")
        if (root._key === "") return
        Store.setView(root._key, root.listFilter, root.listQuery)
        if (Db.viewQuery(root.listQuery) === "") Qt.callLater(root._listShown)
        else Store.reload()
    }
    function _listShown() {
        root._showItems()
        root.itemsUpdated(root.items)
    }

    // Queues the write that `build` makes the args of. Returns "" once it is
    // queued, or why it was refused.
    function _write(kind, op, build, args) {
        if (!Store.ready) return root._refused(kind, args, "not ready")
        var wire
        try {
            wire = build()
        } catch (e) {
            return root._refused(kind, args, e.message)
        }
        var quiet = root._fromScript
        Store.write(root._key, "widget", op, wire, function(r) { root._ended(kind, args, r, quiet) })
        return ""
    }
    function _refused(kind, args, message) {
        root._failWrite(kind, args, message, false)
        return message
    }
    function _failWrite(kind, args, message, quiet) {
        root._log(message)
        if (!quiet && !root._fromScript) {
            root.failed(message)
            root.writeFailed(kind, args, message)
        }
        return message
    }

    // What a finished write does. The snapshot after it lands right after,
    // from the same request, so nothing here asks for a reload.
    function _ended(kind, args, r, quiet) {
        if (!r.ok) {
            root._failWrite(kind, args, Db.errorText(r), quiet)
            return
        }
        if (quiet) return
        if (kind === "add") root.added(r.value, args.type, args.title)
        else if (kind === "setStatus") root.statusChanged(args.id, args.status)
        else if (kind === "update") root.updated(args.id, args.title)
        else if (kind === "convertType") root.typeChanged(args.id)
        else if (kind === "deleteItem") root.itemDeleted(args.id)
        else if (kind === "deleteHistory") root.historyRowDeleted(args.id)
        else if (kind === "clearHistory") root.historyCleared()
        else if (kind === "backup") root.backedUp(r.value)
    }

    function add(type, title, body) {
        var t = String(title || "").trim()
        if (t === "") return root.fail("add: empty title")
        var ty = type === "todo" ? "todo" : "note"
        var b = String(body || "")
        return root._write("add", "item.add", function() { return { type: ty, title: t, body: b } },
            { type: ty, title: t, body: b })
    }

    function setStatus(id, status) {
        var s = status === 1 ? 1 : 0
        return root._write("setStatus", "item.status", function() { return { id: Db.wholeId(id), status: s } },
            { id: Number(id), status: s })
    }

    // Type is fixed on edit: use convertType() to change it.
    function update(id, title, body) {
        var t = String(title || "").trim()
        if (t === "") return root.fail("update: empty title")
        var b = String(body || "")
        return root._write("update", "item.update", function() { return { id: Db.wholeId(id), title: t, body: b } },
            { id: Number(id), title: t, body: b })
    }

    // Emits typeChanged(id).
    function convertType(id) {
        return root._write("convertType", "item.convert", function() { return { id: Db.wholeId(id) } }, { id: Number(id) })
    }

    // Puts the item just before `anchorId`, or just after it when `after`,
    // inside its block. The list shows the move before the write lands.
    function move(id, anchorId, after) {
        var error = root._write("move", "item.move",
            function() { return { id: Db.wholeId(id), anchorId: Db.wholeId(anchorId), after: !!after } },
            { id: Number(id), anchorId: Number(anchorId), after: !!after })
        if (error === "") {
            root._moved = true
            root.items = Db.movedRows(root.items, id, anchorId, after)
        }
        return error
    }

    // Emits itemDeleted(id).
    function deleteItem(id) {
        return root._write("deleteItem", "item.delete", function() { return { id: Db.wholeId(id) } }, { id: Number(id) })
    }

    // Emits historyRowDeleted(id).
    function deleteHistory(id) {
        return root._write("deleteHistory", "history.delete", function() { return { id: Db.wholeId(id) } }, { id: Number(id) })
    }

    function clearHistory() {
        return root._write("clearHistory", "history.clear", function() { return {} }, null)
    }

    // Copies the database to scratchpad-<today>.db beside it, in the write
    // queue, so it never copies a write halfway. The day is this side's local
    // date: the binary has no time zone.
    function backup() {
        if (!Store.ready) return root.fail("not ready")
        var day = Qt.formatDate(new Date(), "yyyy-MM-dd")
        return root._write("backup", "backup", function() { return { day: day } }, { day: day })
    }

    // The settings row is written here only; the service's view, which reads
    // the same row, cannot write it, and the binary refuses it from the
    // service (ADR-0016). "" once queued, or why it was refused. The patch is
    // laid over the row at once, so a control never snaps back while the
    // write runs. A failed write drops its keys and the control shows the
    // file again.
    function setSettings(patch) {
        if (!Store.ready) return root._refused("settings", null, "not ready")
        var cells
        try {
            cells = Db.settingsCells(patch)
        } catch (e) {
            return root._refused("settings", null, e.message)
        }
        var id = Store.write(root._key, "widget", "settings.set", { values: cells }, function(r) { root._settingsEnded(id, r) })
        for (var key in patch) root._settingsPatch[key] = { value: patch[key], id: id }
        root._showSettings()
        return ""
    }

    function _settingsEnded(id, r) {
        if (r.ok) return
        root.fail("Setting not saved: " + Db.errorText(r))
        for (var key in root._settingsPatch) {
            if (root._settingsPatch[key].id === id) delete root._settingsPatch[key]
        }
        root._showSettings()
    }

    // True when keeping `days` of history would remove an entry now.
    function wouldPruneHistory(days) {
        return Db.prunes(days, root.oldestHistory, Db.now())
    }

    // Entries age while nothing is written, so opening the panel applies the
    // Keep choice. It writes only when an entry is past the cutoff, so an
    // open on a pruned history fires no watcher and reloads no view.
    function pruneHistoryIfDue() {
        var days = root.settings.historyDays
        if (!root.wouldPruneHistory(days)) return ""
        return root._write("pruneHistory", "history.prune", function() { return { days: Db.wholeIn(days, 1, 36500) } }, null)
    }
}
