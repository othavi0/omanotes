pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "Db.js" as Db

// The one door to the database for the whole shell (ADR-0018). Every ItemsDb
// (one per bar widget) and the service's AlarmsDb are views over it, so a
// reload is one spawn of bin/omanotes-db whatever the number of monitors, and
// the shell holds one copy of the rows. It keeps the write queue, the two
// lanes, the watcher and the snapshot, and does nothing while no view is
// attached: no watcher, no spawn.
//
// A request carries the writes queued so far, in order, and asks for the
// snapshot after them, so a write and the reload it causes are one spawn.
// Writes run in one lane and reads in another, so a write that waits on a
// lock outside never holds up the list. A read that ran before a snapshot
// already shown and reads an older file (by its change counter, the stamp)
// is dropped, so the two lanes never take the views back in time.
QtObject {
    id: root

    // $XDG_DATA_HOME/omarchy, falling back to ~/.local/share/omarchy.
    readonly property string dataDir: {
        var xdg = Quickshell.env("XDG_DATA_HOME")
        if (xdg && String(xdg) !== "") return String(xdg) + "/omarchy"
        return String(Quickshell.env("HOME")) + "/.local/share/omarchy"
    }
    readonly property string dbPath: root.dataDir + "/scratchpad.db"

    // The last snapshot, one copy for every view. `ready` turns true when the
    // first one lands: the file exists and is at the current schema.
    property bool ready: false
    readonly property bool writing: root._writesInFlight > 0
    property var settings: Db.parseSettings(null).settings
    property real dbBytes: 0
    property var counts: Db.parseCounts(null)
    property var allItems: []
    property var itemsById: ({})
    property var history: []
    property var alarms: []
    // View key -> { filter, query, ids }: the search each view had when the
    // snapshot was read, and the ids it matched, in list order.
    property var matches: ({})
    // The id of the last write the shown rows include. A view drops what it
    // laid over the rows for a write once this reaches that write's id.
    property int covered: 0

    // Every snapshot that landed. `changed` is false when the file was as the
    // views already show it: the rows are the same objects then.
    signal snapshotApplied(bool changed)
    // A read that failed, as the words to show.
    signal failed(string message)

    // Attaches a view and returns its key. The first view starts the Store,
    // and after a time with no view (a plugin reload) it reads the file again:
    // nothing watched it meanwhile.
    function attach() {
        var key = "v" + (++root._lastKey)
        root._attached[key] = { filter: "all", query: "" }
        root._clients += 1
        if (root._binary === "") root._binary = root._binaryPath()
        if (root._clients === 1 || (!root.ready && root.readLane.sent === null)) root.reload()
        return key
    }
    function detach(key) {
        if (!(key in root._attached)) return
        delete root._attached[key]
        root._clients -= 1
    }

    // The search a view shows. A type filter alone needs no spawn: the view
    // narrows the rows it has. A search rides the next request.
    function setView(key, filter, query) {
        if (key in root._attached) root._attached[key] = { filter: String(filter), query: String(query) }
    }

    // Queues a write and returns its id. `done` gets { ok, value } or
    // { ok: false, err, detail } once its turn has run, in the order the
    // writes were made, and before the snapshot that follows them lands.
    // `by` is "widget" or "service": the binary refuses what that side may
    // not write (ADR-0015, ADR-0016).
    function write(key, by, op, args, done) {
        var w = { id: ++root._lastWrite, key: key, by: by, op: op, at: Db.now(), args: args, done: done }
        w.bytes = Db.utf8Length(Db.request([root._wire(w)], null))
        root._queue.push(w)
        root._writesInFlight += 1
        Qt.callLater(root._pump)
        return w.id
    }

    // Asks for a fresh snapshot. A read already running is not interrupted:
    // its answer is dropped and the read runs again when it ends.
    function reload() {
        root._dirty = true
        Qt.callLater(root._pump)
    }
    // The watcher asks through this one timer.
    function reloadSoon() {
        reloadDebounce.restart()
    }

    property int _clients: 0
    property int _lastKey: 0
    property var _attached: ({})
    property var _queue: []
    property int _lastWrite: 0
    property int _doneWrite: 0             // the last write whose result landed; one lane, so it only grows
    property int _writesInFlight: 0
    property bool _dirty: false
    property string _binary: ""
    property real _stamp: -1               // the file's change counter at the shown snapshot
    property int _shown: 0                 // how many snapshots with rows were shown

    function _log(message) {
        console.error("omanotes db: " + message)
        return message
    }

    // bin/omanotes-db.<machine>, beside data/. The kernel names the machine
    // as `uname -m` does, and reading it costs no spawn.
    function _binaryPath() {
        root._arch.path = "/proc/sys/kernel/arch"
        var machine = String(root._arch.text()).trim()
        return decodeURIComponent(String(Qt.resolvedUrl("../bin/omanotes-db." + machine)).replace(/^file:\/\//, ""))
    }

    function _wire(w) {
        return { id: w.id, by: w.by, op: w.op, at: w.at, args: w.args }
    }

    // The snapshot a request asks for: after the stamp shown, with the search
    // of each view, cut as the view compares it. The binary answers the
    // searches even when the file did not move, so a search costs its ids.
    function _sync() {
        var views = []
        for (var key in root._attached) {
            var v = root._attached[key]
            var query = Db.viewQuery(v.query)
            if (query !== "") views.push({ key: key, filter: v.filter, query: query })
        }
        return { since: root._stamp, views: views }
    }

    // What a lane carries: the writes, the request body, and what the answer
    // is judged against when it lands.
    function _request(writes) {
        var sync = root._sync()
        return {
            writes: writes,
            since: sync.since,
            views: sync.views,
            shownBefore: root._shown,
            covers: writes.length > 0 ? writes[writes.length - 1].id : root._doneWrite,
            body: Db.request(writes.map(root._wire), sync)
        }
    }

    function _pump() {
        if (root._clients === 0 || root._binary === "") return
        root._pumpWrites()
        root._pumpReads()
    }

    function _pumpWrites() {
        if (root.writeLane.sent !== null || root.writeLane.running || root._queue.length === 0) return
        // The request stays under the binary's cap: what does not fit waits
        // for the next request, and a write over the cap alone is refused.
        var room = Db.MAX_REQUEST_BYTES - Db.utf8Length(Db.request([], root._sync())) - 64
        var batch = []
        while (root._queue.length > 0 && room - root._queue[0].bytes > 0) {
            room -= root._queue[0].bytes + 1
            batch.push(root._queue.shift())
        }
        if (batch.length === 0) {
            root._landWrite(root._queue.shift(), { ok: false, err: "too_large", detail: "" })
            Qt.callLater(root._pump)
            return
        }
        root.writeLane.send(Db.command(root._binary, root.dbPath), root._request(batch))
    }

    function _pumpReads() {
        if (root.readLane.sent !== null || root.readLane.running || !root._dirty) return
        root._dirty = false
        root.readLane.send(Db.command(root._binary, root.dbPath), root._request([]))
    }

    function _landWrite(w, result) {
        root._writesInFlight -= 1
        root._doneWrite = w.id
        if (w.key in root._attached) w.done(result)
    }

    function _result(results, id) {
        for (var i = 0; i < results.length; ++i) {
            var r = results[i]
            if (r.id !== id) continue
            if (typeof r.err === "string") return { ok: false, err: r.err, detail: String(r.detail || "") }
            return { ok: true, value: r.value === undefined ? null : r.value }
        }
        return { ok: false, err: "crash", detail: "no result" }
    }

    // What one finished request did. The writes hear their results first,
    // in order; then the snapshot lands, or the read failure is told and the
    // Store asks again with back-off.
    function _finish(lane, exitCode, crashed, out, err, neverStarted) {
        var sent = lane.sent
        if (sent === null) return
        lane.sent = null
        var answer = neverStarted ? { ok: false, err: "no_binary", detail: root._binary } : Db.reply(exitCode, crashed, out, err)
        for (var i = 0; i < sent.writes.length; ++i) {
            root._landWrite(sent.writes[i], answer.ok ? root._result(answer.results, sent.writes[i].id)
                : { ok: false, err: answer.err, detail: answer.detail })
        }
        var failure = answer.ok ? answer.syncErr : answer
        if (failure) {
            // A request with writes that failed whole was told to the views
            // that wrote; a read that failed is told to every view.
            if (answer.ok || sent.writes.length === 0) {
                var said = (root.ready ? "read failed: " : "") + Db.errorText(failure)
                root._log(said)
                root.failed(said)
            }
            initRetry.start()
        } else if (answer.snapshot) {
            initRetry.interval = 500
            // A read asked for while this one ran makes its answer stale.
            if (sent.writes.length > 0 || !root._dirty) root._apply(answer.snapshot, sent)
        }
        Qt.callLater(root._pump)
    }

    // The searches a request carried and the ids each matched. A search
    // SQLite refused matched nothing, and the journal says why.
    function _matchesOf(snap, views) {
        var out = {}
        for (var j = 0; j < views.length; ++j) {
            var v = views[j]
            var found = (snap.matches || {})[v.key]
            if (found && !Array.isArray(found)) root._log("search failed: " + Db.errorText(found))
            out[v.key] = { filter: v.filter, query: v.query, ids: Array.isArray(found) ? found : [] }
        }
        return out
    }

    function _apply(snap, sent) {
        if (snap.unchanged) {
            // Answered against the snapshot this request knew; if another
            // landed since, it no longer says anything about what is shown.
            if (sent.since !== root._stamp) {
                root.reload()
                return
            }
            root.matches = root._matchesOf(snap, sent.views)
            root.covered = Math.max(root.covered, sent.covers)
            root.snapshotApplied(false)
            return
        }
        // The file is older than the one shown, and this request was sent
        // before that one was shown, so the one shown was read later and
        // holds this request's writes too. A request sent after it is newer
        // whatever its stamp: the file may have been replaced.
        if (snap.stamp >= 0 && snap.stamp < root._stamp && sent.shownBefore < root._shown) {
            root.covered = Math.max(root.covered, sent.covers)
            return
        }
        root._shown += 1
        root._stamp = snap.stamp
        var read = Db.parseSettings(snap.settings)
        root.settings = read.settings
        root.dbBytes = read.bytes
        root.counts = Db.parseCounts(snap.counts)
        root.history = snap.history
        root.alarms = Db.parseAlarms(snap.alarms)
        var byId = {}
        for (var i = 0; i < snap.items.length; ++i) byId[snap.items[i].id] = snap.items[i]
        root.itemsById = byId
        root.allItems = snap.items
        root.matches = root._matchesOf(snap, sent.views)
        root.covered = Math.max(root.covered, sent.covers)
        if (!root.ready) {
            root.ready = true
            // A watch set while the folder did not exist yet watches nothing.
            dbFile.reload()
        }
        root.snapshotApplied(true)
    }

    // QtObject has no default property, so the lanes, the files and the
    // timers are explicit properties.
    property Lane writeLane: Lane {
        onFinished: function(exitCode, crashed, out, err, neverStarted) { root._finish(root.writeLane, exitCode, crashed, out, err, neverStarted) }
        onIdle: Qt.callLater(root._pump)
    }
    property Lane readLane: Lane {
        onFinished: function(exitCode, crashed, out, err, neverStarted) { root._finish(root.readLane, exitCode, crashed, out, err, neverStarted) }
        onIdle: Qt.callLater(root._pump)
    }

    property FileView _arch: FileView {
        blockLoading: true
        printErrors: false
    }

    // The watcher needs the path, not the bytes: preloaded, every copy of
    // the shell's plugin kept the whole database file in memory.
    property FileView dbFile: FileView {
        path: root._clients > 0 ? root.dbPath : ""
        watchChanges: true
        preload: false
        printErrors: false
        onFileChanged: {
            if (root.ready) root.reloadSoon()
        }
    }

    property Timer reloadDebounce: Timer {
        interval: 80
        repeat: false
        onTriggered: root.reload()
    }

    // The file is locked, the binary is missing or a read failed: ask again
    // from 500 ms up to every 30 s, never in a loop.
    property Timer initRetry: Timer {
        interval: 500
        repeat: false
        onTriggered: {
            interval = Math.min(interval * 2, 30000)
            root.reload()
        }
    }
}
