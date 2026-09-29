import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "data" as Data
import "data/Alarm.js" as Alarm
import "data/Sound.js" as Sound
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

    // The ring reads the settings row and never writes it (ADR-0016). A
    // custom file that is gone plays the default inside the player script,
    // so an alarm never rings silent because a file moved.
    readonly property var settings: store.settings
    readonly property string soundFile: Sound.soundPath(root.settings)
    readonly property string fallbackSoundFile: Sound.pathFor(Sound.DEFAULT_SOUND, null)
    // The sound Settings is testing, "" when none.
    property string previewKey: ""

    readonly property QtObject updater: updates

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

    signal alarmAdded(int id, var caller)
    signal writeFailed(string kind, var record, string message, var caller)
    // `caller` is whoever asked for the preview, so only that page answers.
    signal previewEnded(string key, bool playable, var caller)

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
        if (root.alarms.length + store.unlistedInserts >= Alarm.MAX_ALARMS) return Alarm.MAX_ALARMS + " alarms is the limit"
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

    // Plays `file` once at `volume`, or stops it when `key` is already
    // playing. "" or why it was refused: a ring owns the speaker. It never
    // touches the ring's latch, so a bad test file cannot silence a ring.
    function togglePreview(key, file, volume, caller) {
        if (root.ringing) return "An alarm is ringing"
        if (root.previewKey === key) {
            root.stopPreview()
            return ""
        }
        root.previewKey = key
        root._queuedPreview = { key: key, caller: caller || null,
            command: ["bash", "-c", root.soundScript, "omanotes-preview", String(file), String(volume)] }
        if (preview.running) preview.running = false
        else root._startQueuedPreview()
        return ""
    }

    function stopPreview() {
        root._queuedPreview = null
        root.previewKey = ""
        if (preview.running) preview.running = false
    }

    property var _queuedPreview: null
    function _startQueuedPreview() {
        var next = root._queuedPreview
        root._queuedPreview = null
        if (!next || preview.running) return
        preview.key = next.key
        preview.caller = next.caller
        preview.command = next.command
        preview.running = true
    }

    function _drop(id) {
        root.ringing = Alarm.ringWithout(root.ringing, Number(id))
    }

    function _ring(ids) {
        root.stopPreview()
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

    function _dropLostOutside() {
        if (!root.ringing) return
        var events = root.ringing.events
        for (var i = 0; i < events.length; ++i) {
            if (Alarm.lostOutside(root.alarmsById[events[i].id])) root._drop(events[i].id)
        }
    }

    onRingingChanged: {
        if (root.ringing !== null) return
        root._stopSound()
    }

    onSettingsChanged: {
        if (root.settings.soundOn) root._ensureSound()
        else root._stopSound()
    }

    function _stopSound() {
        soundLoop.stop()
        if (sound.running) sound.running = false
    }

    Data.AlarmsDb {
        id: store
        Component.onCompleted: store.init()
        onShown: root._dropLostOutside()
        onAlarmAdded: function(id, caller) { root.alarmAdded(id, caller) }
        onAlarmWriteFailed: function(kind, record, message, caller) { root.writeFailed(kind, record, message, caller) }
    }

    // The shell's one Updater: every panel uses it, and it makes the only
    // automatic check, so several monitors never mean several fetches. A
    // test drives the clock and never fetches. The reload and the restart an
    // update sets off would drop a ring, so a ring blocks it.
    Data.Updater {
        id: updates
        daily: root.clockRunning && root.settings.checkUpdates
        checkUpdates: root.settings.checkUpdates
        blocked: root.ringing !== null
    }

    SystemClock {
        id: clock
        enabled: root.clockRunning
        precision: SystemClock.Seconds
        // Not Date.now(): `date` is rounded to the second and fires early.
        onDateChanged: root.tick(clock.date.getTime())
    }

    // Chime's player chain (MIT, see NOTICE). $2 is the volume, 0 to 100,
    // turned into each player's scale with integer maths under LC_ALL=C, so
    // no locale puts a comma in pw-play's 0.50. $3 plays when $1 is gone.
    // Without $4 it plays once (the preview). With $4 it is the ring: one
    // process that plays, waits the gap and plays again, so a ring of a short
    // sound is not a new spawn every half second. The gap is a read on the
    // service's stdin pipe, which ends when the shell is gone. The shell
    // SIGKILLs the process when it quits, so no trap runs then: setpriv makes
    // the player die with it. A player that fails ends the ring's process
    // with its code, for the latch in onExited.
    readonly property int unplayableExit: 3
    readonly property int repeatGapMs: 350
    readonly property string soundScript: 'export LC_ALL=C; f="$1"; v="${2:-100}"; '
        + '[[ -f "$f" && -r "$f" ]] || f="${3:-}"; '
        + '[[ -n "$f" && -f "$f" && -r "$f" ]] || { sleep 2; exit ' + unplayableExit + '; }; '
        + 'if command -v pw-play >/dev/null 2>&1; then p=(pw-play --volume "$((v / 100)).$(printf %02d $((v % 100)))" -- "$f"); '
        + 'elif command -v paplay >/dev/null 2>&1; then p=(paplay --volume "$((v * 65536 / 100))" -- "$f"); '
        + 'elif command -v mpv >/dev/null 2>&1; then p=(mpv --no-video --no-terminal --really-quiet --volume="$v" -- "$f"); '
        + 'elif command -v ffplay >/dev/null 2>&1; then p=(ffplay -nodisp -autoexit -loglevel quiet -volume "$v" "$f"); '
        + 'else sleep 2; exit ' + unplayableExit + '; fi; '
        + '[[ -n "${4:-}" ]] || exec "${p[@]}"; '
        + '! command -v setpriv >/dev/null 2>&1 || p=(setpriv --pdeathsig TERM -- "${p[@]}"); '
        + "k=; trap 'exit 143' TERM; trap '[[ -z \"$k\" ]] || kill \"$k\" 2>/dev/null' EXIT; "
        + 'while :; do "${p[@]}" & k=$!; wait "$k" || exit; k=; '
        + 'read -rt ' + (repeatGapMs / 1000) + '; (( $? > 128 )) || exit 0; done'
    readonly property int quickFailureMs: 1500
    readonly property int maxQuickFailures: 3
    property double soundStartedAt: 0
    property int soundFailures: 0

    function _ensureSound() {
        if (!root.ringing || !root.settings.soundOn || root.soundBroken || sound.running) return
        root.soundStartedAt = Date.now()
        sound.command = ["bash", "-c", root.soundScript, "omanotes-ring", root.soundFile,
            String(root.settings.volume), root.fallbackSoundFile, "repeat"]
        sound.running = true
    }

    Process {
        id: sound
        // Held open for the ring's gap, and closed when the shell is gone.
        stdinEnabled: true
        onExited: function(exitCode) {
            if (!root.ringing || !root.settings.soundOn) return
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

    Process {
        id: preview
        property string key: ""
        property var caller: null
        onExited: function(exitCode) {
            var key = preview.key
            var caller = preview.caller
            if (root._queuedPreview) Qt.callLater(root._startQueuedPreview)
            else if (root.previewKey === key) root.previewKey = ""
            root.previewEnded(key, exitCode !== root.unplayableExit, caller)
        }
    }

    Timer {
        id: soundLoop
        interval: root.repeatGapMs
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
