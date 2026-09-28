import QtQuick
import Quickshell.Io
import "Db.js" as Db

DbCore {
    id: root

    property var alarms: []
    property var alarmsById: ({})
    property bool alarmsLoaded: false
    readonly property int unlistedInserts: root._insertSeqs.length
    signal shown()
    signal alarmAdded(int id, var caller)
    signal alarmWriteFailed(string kind, var record, string message, var caller)

    property var _alarmRows: []
    property var _insertSeqs: []
    property var _alarmPending: ({})
    property int _alarmSeq: 0             // the last seq handed to a write
    property int _alarmDoneSeq: 0         // the highest seq whose write ended. The queue is FIFO, so it only grows
    property int _alarmsReadSeq: 0        // _alarmDoneSeq when the running alarms read started
    property bool _alarmsStale: false

    onReloadDue: root.listAlarms()
    onWriteRefused: function(kind, args, message) { root._log(message) }
    onWriteEnded: function(kind, args, exitCode, output, errors) { root._alarmWriteEnded(kind, args, exitCode, output, errors) }

    property Process alarmsProcess: Process {
        stdout: StdioCollector {
            id: alarmsStdout
            waitForEnd: true
        }
        stderr: StdioCollector {
            id: alarmsStderr
            waitForEnd: true
        }
        onExited: function(exitCode) {
            var rows = root._parsed("alarms", exitCode, alarmsStdout, alarmsStderr, Db.parseAlarms)
            if (root._alarmsStale) {
                Qt.callLater(root.listAlarms)
                return
            }
            if (rows === null) return
            root._alarmsLanded(rows)
        }
    }

    function listAlarms() {
        if (!root.ready) return
        if (root.alarmsProcess.running) { root._alarmsStale = true; return }
        root._alarmsStale = false
        root._alarmsReadSeq = root._alarmDoneSeq
        root.alarmsProcess.command = Db.sqliteCommand(root.dbPath, Db.alarmsSql(), true)
        root.alarmsProcess.running = true
    }

    function _alarmsLanded(rows) {
        root._alarmRows = rows
        var pending = root._alarmPending
        for (var id in pending) {
            if (pending[id].seq <= root._alarmsReadSeq && !pending[id].retry && !pending[id].unwritable) delete pending[id]
        }
        root._insertSeqs = root._insertSeqs.filter(function(seq) { return seq > root._alarmsReadSeq })
        root._show(Db.mergeAlarms(rows, pending))
        root.alarmsLoaded = true
    }

    // Lays `record` (null to delete) over its row now and queues the write.
    // Returns "" or why it was refused.
    function _pendAlarm(id, record, caller) {
        if (!root.ready) return root._log("not ready")
        var kind = record === null ? "deleteAlarm" : "saveAlarm"
        var seq = root._alarmSeq + 1
        var error = root._write(kind, function() { return record === null ? Db.deleteAlarmSql(id) : Db.saveAlarmSql(record) },
            { id: Number(id), seq: seq, record: record, caller: caller || null })
        root._alarmSeq = seq
        root._alarmPending[Number(id)] = { seq: seq, record: record, retry: false, unwritable: error !== "" }
        root._show(Db.mergeAlarms(root._alarmRows, root._alarmPending))
        return error
    }

    function _show(list) {
        var byId = {}
        for (var i = 0; i < list.length; ++i) byId[list[i].id] = list[i]
        root.alarmsById = byId
        root.alarms = list
        root.shown()
    }

    function saveAlarm(record, caller) {
        return root._pendAlarm(record.id, record, caller)
    }

    function deleteAlarm(id, caller) {
        return root._pendAlarm(id, null, caller)
    }

    // Not laid over: the row has no id until the insert lands.
    function insertAlarm(record, caller) {
        var seq = root._alarmSeq + 1
        var error = root._write("insertAlarm", function() { return Db.insertAlarmSql(record) },
            { seq: seq, record: record, caller: caller || null })
        if (error !== "") return error
        root._alarmSeq = seq
        root._insertSeqs = root._insertSeqs.concat([seq])
        return ""
    }

    // What a finished alarm write does to the overlay. A write that failed
    // keeps its entry and is retried with back-off, and the retry sends the
    // newest state of that alarm because a later change replaced the entry.
    // A row that is gone (CHANGES 0) only drops the entry, quietly.
    function _alarmWriteEnded(kind, args, exitCode, output, errors) {
        root._alarmDoneSeq = args.seq
        var error = exitCode !== 0 ? root._log(Db.errorText(errors, exitCode)) : ""
        if (error !== "" && args.caller) root.alarmWriteFailed(kind, args.record, error, args.caller)
        if (kind === "insertAlarm") {
            if (error !== "") {
                root._insertSeqs = root._insertSeqs.filter(function(seq) { return seq !== args.seq })
                return
            }
            root.alarmAdded(Db.parseId(output), args.caller)
            root.reloadSoon()
            return
        }
        var entry = root._alarmPending[args.id]
        var current = !!entry && entry.seq === args.seq
        if (error !== "") {
            if (current) {
                entry.retry = true
                alarmRetry.start()
            }
            return
        }
        alarmRetry.interval = 500
        if (!Db.parseFound(output)) {
            if (current) delete root._alarmPending[args.id]
            root._log("alarm not found")
        }
        root.reloadSoon()
    }

    property Timer alarmRetry: Timer {
        interval: 500
        repeat: false
        onTriggered: {
            interval = Math.min(interval * 2, 30000)
            var pending = root._alarmPending
            for (var id in pending) {
                if (pending[id].retry && root._pendAlarm(Number(id), pending[id].record, null) !== "") restart()
            }
        }
    }
}
