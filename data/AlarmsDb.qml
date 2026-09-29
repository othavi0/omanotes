import QtQuick
import "Db.js" as Db

// The service's view of the Store (data/Store.qml), and the only writer of
// the alarms table (ADR-0015): it attaches as the service, so every write it
// makes goes out as the service's, and the binary refuses alarm writes from
// anyone else. It lays each alarm it
// wrote over its row until a snapshot read after that write lands, and
// retries a write that failed with back-off. It reads the settings row and
// never writes it (ADR-0016).
QtObject {
    id: root

    readonly property string dataDir: Store.dataDir
    readonly property string dbPath: Store.dbPath
    readonly property bool ready: Store.ready
    readonly property var settings: Store.settings

    property var alarms: []
    property var alarmsById: ({})
    property bool alarmsLoaded: false
    readonly property int unlistedInserts: root._inserts.length
    signal shown()
    signal failed(string message)
    signal alarmAdded(int id, var caller)
    signal alarmWriteFailed(string kind, var record, string message, var caller)

    property string _key: ""
    // The ids of the Store writes of inserts no snapshot has listed yet.
    property var _inserts: []
    // alarm id -> { write, record, retry, unwritable }: what is laid over the
    // rows. `write` is the id of the Store write that sends it.
    property var _pending: ({})

    function init() {
        if (root._key !== "") return
        root._key = Store.attach("service")
        root._land()
    }
    Component.onDestruction: if (root._key !== "") Store.detach(root._key)

    // QtObject has no default property, so the connection is an explicit property.
    property Connections _store: Connections {
        target: Store
        function onSnapshotApplied(changed) { root._land() }
        function onFailed(message) { root.failed(message) }
    }

    // A snapshot drops a pending entry only once it was read after that write
    // ended, so a read that ran before the write cannot bring the old row back.
    function _land() {
        if (!Store.ready) return
        var pending = root._pending
        for (var id in pending) {
            if (pending[id].write <= Store.covered && !pending[id].retry && !pending[id].unwritable) delete pending[id]
        }
        root._inserts = root._inserts.filter(function(write) { return write > Store.covered })
        root._show(Db.mergeAlarms(Store.alarms, pending))
        root.alarmsLoaded = true
    }

    function _show(list) {
        var byId = {}
        for (var i = 0; i < list.length; ++i) byId[list[i].id] = list[i]
        root.alarmsById = byId
        root.alarms = list
        root.shown()
    }

    function _log(message) {
        console.error("omanotes db: " + message)
        return message
    }

    // Lays `record` (null to delete) over its row now and queues the write.
    // Returns "" or why it was refused. A record that cannot be sent stays
    // laid over its row, so a tick still consumes an occurrence once.
    function _pendAlarm(id, record, caller) {
        if (!Store.ready) return root._log("not ready")
        var kind = record === null ? "deleteAlarm" : "saveAlarm"
        var wire
        try {
            wire = record === null ? { id: Db.wholeId(id) } : { id: Db.wholeId(id), alarm: Db.alarmCells(record) }
        } catch (e) {
            root._pending[Number(id)] = { write: 0, record: record, retry: false, unwritable: true }
            root._show(Db.mergeAlarms(Store.alarms, root._pending))
            return root._log(e.message)
        }
        var args = { id: Number(id), record: record, caller: caller || null }
        var write = Store.write(root._key, record === null ? "alarm.delete" : "alarm.save", wire,
            function(r) { root._ended(kind, args, write, r) })
        root._pending[Number(id)] = { write: write, record: record, retry: false, unwritable: false }
        root._show(Db.mergeAlarms(Store.alarms, root._pending))
        return ""
    }

    function saveAlarm(record, caller) {
        return root._pendAlarm(record.id, record, caller)
    }

    function deleteAlarm(id, caller) {
        return root._pendAlarm(id, null, caller)
    }

    // Not laid over: the row has no id until the insert lands.
    function insertAlarm(record, caller) {
        if (!Store.ready) return root._log("not ready")
        var wire
        try {
            wire = { alarm: Db.alarmCells(record) }
        } catch (e) {
            return root._log(e.message)
        }
        var args = { record: record, caller: caller || null }
        var write = Store.write(root._key, "alarm.insert", wire, function(r) { root._ended("insertAlarm", args, write, r) })
        root._inserts = root._inserts.concat([write])
        return ""
    }

    // What a finished alarm write does to the overlay. A write that failed
    // keeps its entry and is retried with back-off, and the retry sends the
    // newest state of that alarm because a later change replaced the entry.
    // A row that is gone only drops the entry, quietly. A write refused for
    // what it is (Db.definitive: the schema, the side, the size) stays laid
    // over its row and is not retried: it would be refused again.
    function _ended(kind, args, write, r) {
        var entry = kind === "insertAlarm" ? undefined : root._pending[args.id]
        var current = !!entry && entry.write === write
        if (!r.ok && r.err === "not_found" && kind !== "insertAlarm") {
            if (current) delete root._pending[args.id]
            root._log("alarm not found")
            return
        }
        var error = r.ok ? "" : root._log(Db.errorText(r))
        if (error !== "" && args.caller) root.alarmWriteFailed(kind, args.record, error, args.caller)
        if (kind === "insertAlarm") {
            if (error !== "") {
                root._inserts = root._inserts.filter(function(w) { return w !== write })
                return
            }
            root.alarmAdded(r.value, args.caller)
            return
        }
        if (error !== "") {
            if (current && Db.definitive(r.err)) entry.unwritable = true
            else if (current) {
                entry.retry = true
                alarmRetry.start()
            }
            return
        }
        alarmRetry.interval = 500
    }

    property Timer alarmRetry: Timer {
        interval: 500
        repeat: false
        onTriggered: {
            interval = Math.min(interval * 2, 30000)
            var pending = root._pending
            for (var id in pending) {
                if (pending[id].retry && root._pendAlarm(Number(id), pending[id].record, null) !== "") restart()
            }
        }
    }
}
