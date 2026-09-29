import QtQuick
import Quickshell.Io
import "Db.js" as Db

// One spawn of bin/omanotes-db at a time. The request goes in on stdin, which
// is closed to end it, and the answer comes back on stdout: one result line
// per write, each as soon as its write ends, then the snapshot (ADR-0020).
// `finished` hands over what Db.reply read of it. The Store runs two lanes:
// writes and reads.
//
// Each rule is a failure measured before this lane existed (ADR-0018):
// - The request is written in onStarted. Written earlier it can be lost, and
//   the binary waits on stdin until it gives up.
// - A start that fails (a missing file, no exec bit) emits no `exited`: only
//   `running` goes back to false. `finished` still fires, with no_binary, so
//   the queue behind it moves on.
// - The environment is empty: a DOTNET_* variable of the session changes
//   the runtime's memory limits (DOTNET_GCHeapHardLimit made it crash), and
//   the binary reads no variable.
// - Each spawn gets collectors of its own, destroyed once its answer is read:
//   one kept across spawns held the text of the last snapshot for as long as
//   the shell ran.
// - A spawn that outlives its limit is killed, and its answer is what it
//   wrote before: a process stuck on a disk would hold the queue forever. The
//   writes whose result lines came out before the kill keep their results.
Process {
    id: lane

    // What is in flight, or null. The Store keeps its own fields beside `body`.
    property var sent: null
    property bool _started: false

    signal finished(var answer)
    // The lane can start the next request. A Process that has just exited can
    // still read as running for a moment, and a start then is swallowed.
    signal idle()

    clearEnvironment: true

    property Component _collector: Component {
        StdioCollector { waitForEnd: true }
    }

    function send(command, request, limitMs) {
        lane.sent = request
        lane._started = false
        lane.command = command
        lane.stdout = lane._collector.createObject(lane)
        lane.stderr = lane._collector.createObject(lane)
        watchdog.interval = limitMs
        lane.stdinEnabled = true
        lane.running = true
    }

    function _end(answer) {
        watchdog.stop()
        var out = lane.stdout
        var err = lane.stderr
        lane.stdout = null
        lane.stderr = null
        if (out) out.destroy()
        if (err) err.destroy()
        lane.finished(answer)
    }

    onStarted: {
        lane._started = true
        watchdog.restart()
        lane.write(lane.sent.body)
        lane.stdinEnabled = false
    }
    onExited: function(exitCode, exitStatus) {
        lane._end(Db.reply(lane.sent.writes.length, exitCode, exitStatus !== 0, lane.stdout ? lane.stdout.text : "", lane.stderr ? lane.stderr.text : ""))
    }
    onRunningChanged: {
        if (lane.running) return
        if (lane.sent !== null && !lane._started) lane._end({ ok: false, err: "no_binary", detail: String(lane.command[0]), log: [] })
        lane.idle()
    }

    property Timer watchdog: Timer {
        repeat: false
        onTriggered: if (lane.running) lane.signal(9)
    }
}
