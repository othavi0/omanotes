import QtQuick
import Quickshell.Io

// One spawn of bin/omanotes-db at a time. The request goes in on stdin, which
// is closed to end it, and the answer comes back on stdout, or on the last
// line of stderr when it failed. The Store runs two lanes: writes and reads.
//
// Three rules, each a failure measured before this lane existed (ADR-0018):
// - The request is written in onStarted. Written earlier it can be lost, and
//   the binary waits on stdin until it gives up after 2 s.
// - A start that fails (a missing file, no exec bit) emits no `exited`: only
//   `running` goes back to false. `finished` still fires, with neverStarted,
//   so the queue behind it moves on.
// - The environment is empty: a DOTNET_* variable of the session changes
//   the runtime's memory limits (DOTNET_GCHeapHardLimit made it crash), and
//   the binary reads no variable.
Process {
    id: lane

    // What is in flight, or null. The Store keeps its own fields beside `body`.
    property var sent: null
    property bool _started: false

    signal finished(int exitCode, bool crashed, string out, string err, bool neverStarted)
    // The lane can start the next request. A Process that has just exited can
    // still read as running for a moment, and a start then is swallowed.
    signal idle()

    clearEnvironment: true
    stdout: StdioCollector {
        id: out
        waitForEnd: true
    }
    stderr: StdioCollector {
        id: err
        waitForEnd: true
    }

    function send(command, request) {
        lane.sent = request
        lane._started = false
        lane.command = command
        lane.stdinEnabled = true
        lane.running = true
    }

    onStarted: {
        lane._started = true
        lane.write(lane.sent.body)
        lane.stdinEnabled = false
    }
    onExited: function(exitCode, exitStatus) {
        lane.finished(exitCode, exitStatus !== 0, out.text, err.text, false)
    }
    onRunningChanged: {
        if (lane.running) return
        if (lane.sent !== null && !lane._started) lane.finished(-1, false, "", "", true)
        lane.idle()
    }
}
