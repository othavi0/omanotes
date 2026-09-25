import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "data" as Data
import "data/Alarm.js" as Alarm
import "ui/Alarms.js" as Alarms
import "ui/Icons.js" as Icons

// The alarm service: the one clock, ring, sound and notification in the
// shell, and the only writer of the alarms table (ADR-0015). Widgets and the
// Alarms tab read its properties and call its functions; it never reaches
// into them. Time comes from tick(), so a test can drive it.
Item {
    id: root

    // Injected by the shell (PluginShellApi).
    property var shell: null

    // Inputs a test overrides when it creates the service. The ring window
    // is a Component so that a test can pass a plain window around the real
    // card: the layer-shell RingWindow has no offscreen backend, so it is
    // only compiled, from its URL, when nothing was injected.
    property bool clockRunning: true
    property var screens: Quickshell.screens
    property Component ringWindow: null
    property string soundFile: "/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga"

    readonly property var alarms: store.alarms
    readonly property bool loaded: store.alarmsLoaded
    property real nowMs: 0
    property var ringing: null
    property bool soundBroken: false

    readonly property var alarmsById: store.alarmsById
    readonly property var next: Alarm.nextAlarm(root.alarms, root.nowMs)
    readonly property bool nextIsSnooze: !!root.next && root.next.at === Number(root.next.alarm.snoozedUntil)
    readonly property string barLabel: root.next ? Alarms.nextText(root.next.at, root.nowMs) : ""
    readonly property string nextSummary: Alarms.nextSummary(root.next ? root.next.at : 0, root.nowMs)
    readonly property int onCount: root.alarms.filter(function(a) { return Alarm.isOn(a, root.nowMs) }).length
    readonly property var ringView: Alarms.ringView(root.ringing, root.alarmsById, root.nowMs)
    readonly property string ringTitle: root.ringView ? root.ringView.title : ""

    // Where the bar is, for the card: the notifications service's rule.
    readonly property string barPosition: root.shell && root.shell.barConfig ? String(root.shell.barConfig.position || "top") : "top"
    readonly property int barClearance: {
        var vertical = root.barPosition === "left" || root.barPosition === "right"
        var size = root.shell && root.shell.bar && !root.shell.bar.barHidden ? Math.max(0, root.shell.bar.barSize)
            : (vertical ? Style.bar.sizeVertical : Style.bar.sizeHorizontal)
        return size + Style.gapsOut
    }

    // `caller` is whatever the Alarms tab passed to the write, so each tab
    // answers only its own writes.
    signal alarmAdded(int id, var caller)
    signal writeFailed(string kind, var record, string message, var caller)

    function tick(nowMs) {
        root.nowMs = nowMs
        if (!root.loaded) return
        var result = Alarm.tick(root.alarms, nowMs)
        var byId = root.alarmsById
        if (result.missed.length > 0) root._notifyMissed(result.missed, byId)
        for (var i = 0; i < result.patches.length; ++i) {
            var p = result.patches[i]
            store.saveAlarm(Alarm.withPatch(byId[p.id], p.patch))
        }
        if (result.ring.length > 0) root._ring(result.ring.map(function(e) { return e.id }))
        root._expire()
    }

    // Each returns "" or why it was refused.
    function addAlarm(fields, caller) {
        if (!root.loaded) return "not ready"
        if (root.alarms.length + store.insertsInFlight >= Alarm.MAX_ALARMS) return Alarm.MAX_ALARMS + " alarms is the limit"
        return store.insertAlarm(Alarm.newAlarm(fields, root.nowMs), caller)
    }

    function updateAlarm(id, fields, caller) {
        var alarm = root.alarmsById[id]
        if (!alarm) return "alarm not found"
        var patch = Alarm.editPatch(alarm, fields, root.nowMs)
        if (patch.armedAt !== undefined) root._drop(id)
        return store.saveAlarm(Alarm.withPatch(alarm, patch), caller)
    }

    function toggleAlarm(id, caller) {
        var alarm = root.alarmsById[id]
        if (!alarm) return "alarm not found"
        var patch = Alarm.enablePatch(alarm, !Alarm.isOn(alarm, root.nowMs), root.nowMs)
        if (!patch.enabled) root._drop(id)
        return store.saveAlarm(Alarm.withPatch(alarm, patch), caller)
    }

    function removeAlarm(id, caller) {
        root._drop(id)
        return store.deleteAlarm(id, caller)
    }

    function snooze() {
        if (!root.ringing) return false
        var events = root.ringing.events
        for (var i = 0; i < events.length; ++i) {
            var alarm = root.alarmsById[events[i].id]
            if (alarm) store.saveAlarm(Alarm.withPatch(alarm, Alarm.snoozePatch(alarm, alarm.snoozeMinutes, false, root.nowMs)))
        }
        return root.stop()
    }

    function stop() {
        if (!root.ringing) return false
        root.ringing = null
        return true
    }

    function _drop(id) {
        root.ringing = Alarm.ringWithout(root.ringing, Number(id))
    }

    function _ring(ids) {
        root.ringing = Alarm.ringWith(root.ringing, ids, root.nowMs)
        root.soundBroken = false
        root.soundFailures = 0
        root._ensureSound()
    }

    function _expire() {
        if (!root.ringing) return
        var out = Alarm.expire(root.ringing.events, root.alarmsById, root.nowMs)
        if (out.keep.length === root.ringing.events.length) return
        for (var i = 0; i < out.snooze.length; ++i) {
            var alarm = root.alarmsById[out.snooze[i]]
            store.saveAlarm(Alarm.withPatch(alarm, Alarm.snoozePatch(alarm, alarm.snoozeMinutes, true, root.nowMs)))
        }
        root.ringing = out.keep.length === 0 ? null : { startedAt: root.ringing.startedAt, events: out.keep }
    }

    function _notifyMissed(missed, byId) {
        var text = Alarms.missedText(missed, byId, root.nowMs)
        Quickshell.execDetached(["omarchy-notification-send", "-g", Icons.alarm, text.headline, text.body])
    }

    onAlarmsChanged: {
        if (!root.ringing) return
        var events = root.ringing.events
        for (var i = 0; i < events.length; ++i) {
            if (Alarm.lostOutside(root.alarmsById[events[i].id])) root._drop(events[i].id)
        }
    }

    onRingingChanged: {
        if (root.ringing !== null) return
        soundLoop.stop()
        if (sound.running) sound.running = false
    }

    Data.AlarmsDb {
        id: store
        Component.onCompleted: store.init()
        onAlarmAdded: function(id, caller) { root.alarmAdded(id, caller) }
        onAlarmWriteFailed: function(kind, record, message, caller) { root.writeFailed(kind, record, message, caller) }
    }

    SystemClock {
        id: clock
        enabled: root.clockRunning
        precision: SystemClock.Seconds
        // Not Date.now(): `date` is rounded to the second and fires early.
        onDateChanged: root.tick(clock.date.getTime())
    }

    // Chime's player chain (MIT, see NOTICE).
    readonly property int unplayableExit: 3
    readonly property string soundScript: 'f="$1"; [[ -f "$f" && -r "$f" ]] || { sleep 2; exit ' + unplayableExit + '; }; '
        + 'if command -v pw-play >/dev/null 2>&1; then exec pw-play -- "$f"; fi; '
        + 'if command -v paplay >/dev/null 2>&1; then exec paplay -- "$f"; fi; '
        + 'if command -v mpv >/dev/null 2>&1; then exec mpv --no-video --no-terminal --really-quiet -- "$f"; fi; '
        + 'if command -v ffplay >/dev/null 2>&1; then exec ffplay -nodisp -autoexit -loglevel quiet "$f"; fi; '
        + 'sleep 2; exit ' + unplayableExit
    readonly property int quickFailureMs: 1500
    readonly property int maxQuickFailures: 3
    property double soundStartedAt: 0
    property int soundFailures: 0

    function _ensureSound() {
        if (!root.ringing || root.soundBroken || sound.running) return
        root.soundStartedAt = Date.now()
        sound.command = ["bash", "-c", root.soundScript, "omanotes-ring", root.soundFile]
        sound.running = true
    }

    Process {
        id: sound
        onExited: function(exitCode) {
            if (!root.ringing) return
            var quickFailure = exitCode !== 0 && Date.now() - root.soundStartedAt < root.quickFailureMs
            if (exitCode === root.unplayableExit || (quickFailure && ++root.soundFailures >= root.maxQuickFailures)) {
                root.soundBroken = true
                console.warn("omanotes: cannot play " + root.soundFile + "; ringing silently")
                return
            }
            if (!quickFailure) root.soundFailures = 0
            soundLoop.restart()
        }
    }

    Timer {
        id: soundLoop
        interval: 350
        onTriggered: root._ensureSound()
    }

    // A window has no visual parent to reach the service through, so each
    // instance is handed it, as BarWidget.injectPanel hands the panel its Db.
    Variants {
        id: ringWindows
        model: root.ringing !== null && root.ringWindow !== null ? root.screens : []
        delegate: root.ringWindow
        onInstancesChanged: {
            for (var i = 0; i < ringWindows.instances.length; ++i) {
                if ("service" in ringWindows.instances[i]) ringWindows.instances[i].service = root
            }
        }
    }

    Component.onCompleted: {
        if (root.ringWindow === null) {
            var window = Qt.createComponent(Qt.resolvedUrl("ui/RingWindow.qml"))
            if (window.status === Component.Error) console.error("omanotes: no ring card: " + window.errorString())
            root.ringWindow = window
        }
        if (root.clockRunning) root.tick(clock.date.getTime())
    }
}
