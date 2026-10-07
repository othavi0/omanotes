pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../data/Sound.js" as Sound
import "Icons.js" as Icons
import "Tone.js" as Tone

// The Alarm sound page: the switch, the sound, the volume and a test. Every
// control saves when it is clicked or released (ADR-0016). Playing a sound
// needs the service, which owns the speaker; without it the rest still
// saves, and the play buttons say why they do nothing.
ColumnLayout {
    id: root

    property var settings: ({})
    property QtObject service: null
    property var toast: null
    property QtObject bar: null
    property color foreground: Color.foreground

    signal save(var patch)

    readonly property string previewKey: root.service ? root.service.previewKey : ""
    readonly property bool soundOn: !!root.settings.soundOn
    readonly property bool hasCustomFile: Sound.customFile(root.settings) !== ""
    readonly property string noService: "Needs the Omanotes service"

    function play(key) {
        if (!root.service) return
        var error = root.service.togglePreview(key, Sound.pathFor(key, root.settings), Math.round(volume.liveValue), root)
        if (error !== "" && root.toast) root.toast.show(error)
    }

    function test() {
        if (!root.service) return
        if (root.previewKey !== "") root.service.stopPreview()
        else root.play(root.settings.sound)
    }

    function chooseFile() {
        if (!picker.running) picker.running = true
    }

    // Lives with the panel, which outlives a close, so a file picked after
    // the chooser took focus still saves.
    Process {
        id: picker
        // Omarchy's helper by its full path. It opens a window, so it keeps
        // the shell's environment.
        command: [(Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/bin/omarchy-file-select",
            "--title", "Alarm sound", "--extensions", "oga ogg wav mp3 flac opus"]
        stdout: StdioCollector { id: picked; waitForEnd: true }
        onExited: function(exitCode) {
            var path = String(picked.text || "").trim().split("\n")[0]
            if (exitCode === 0 && path !== "") root.save({ sound: Sound.CUSTOM, soundFile: path })
            else if (exitCode !== 1 && root.toast) root.toast.show("No file chooser", true)
        }
    }

    Connections {
        target: root.service
        // The service serves every monitor's panel: only the page whose
        // Test it was answers, with the sound it tested.
        function onPreviewEnded(key, playable, caller) {
            if (!playable && caller === root && root.toast) root.toast.show("Can't play " + Sound.nameOf(key, root.settings))
        }
    }

    spacing: Style.spacing.lg

    SettingRow {
        Layout.fillWidth: true
        label: "Sound"
        caption: "Plays while an alarm rings. Off rings with the card only."
        foreground: root.foreground

        Segment {
            fill: false
            options: [{ value: "on", label: "On" }, { value: "off", label: "Off" }]
            value: root.soundOn ? "on" : "off"
            foreground: root.foreground
            onPicked: function(v) { root.save({ soundOn: v === "on" }) }
        }
    }

    component PlayButton: ActionButton {
        property string key: ""
        property string name: ""
        readonly property bool playing: root.previewKey === key
        Layout.preferredWidth: Style.spacing.controlHeight
        horizontalPadding: 0
        iconText: playing ? Icons.stop : Icons.play
        tooltipText: !root.service ? root.noService : (playing ? "Stop" : "Test " + name)
        foreground: !root.service ? Util.alpha(root.foreground, Tone.muted)
            : playing ? Color.accent : Util.alpha(root.foreground, Tone.secondary)
        onClicked: root.play(key)
    }

    // One row of the list: the whole row picks the sound.
    component SoundRow: Rectangle {
        id: row
        property bool picked: false
        property string name: ""
        property string detail: ""
        default property alias trailing: tail.data
        signal chosen()

        Layout.fillWidth: true
        Layout.preferredHeight: Style.spacing.controlHeight
        color: row.picked ? Style.selectedFillFor(root.foreground, Color.accent)
            : rowMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

        MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: row.chosen()
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.spacing.controlPaddingX
            spacing: Style.spacing.md

            Rectangle {
                Layout.preferredWidth: Style.space(12)
                Layout.preferredHeight: Style.space(12)
                radius: width / 2
                color: "transparent"
                border.width: Style.normalBorderWidth
                border.color: row.picked ? root.foreground : Util.alpha(root.foreground, Tone.muted)

                Rectangle {
                    visible: row.picked
                    anchors.centerIn: parent
                    width: Style.space(6)
                    height: width
                    radius: width / 2
                    color: root.foreground
                }
            }
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: row.name
                elide: Text.ElideMiddle
                color: row.picked ? Style.selectedStateColor(root.foreground, Color.accent) : root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
            }
            Text {
                textFormat: Text.PlainText
                visible: row.detail !== ""
                text: row.detail
                color: Util.alpha(root.foreground, Tone.muted)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
            }
            RowLayout {
                id: tail
                spacing: 0
            }
        }
    }

    // Off greys the sound choice out: the ring plays nothing, so a pick here
    // would change nothing the user hears.
    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: soundList.implicitHeight + 2 * Style.normalBorderWidth
        radius: Style.cornerRadius
        clip: true
        color: "transparent"
        border.width: Style.normalBorderWidth
        border.color: Style.normalBorderFor(root.foreground, Color.accent)
        enabled: root.soundOn
        opacity: root.soundOn ? 1 : Tone.muted

        ColumnLayout {
            id: soundList
            anchors.fill: parent
            anchors.margins: Style.normalBorderWidth
            spacing: 0

            Repeater {
                model: Sound.SOUNDS
                delegate: ColumnLayout {
                    id: entry
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true
                    spacing: 0

                    PanelSeparator {
                        visible: entry.index > 0
                        Layout.fillWidth: true
                        foreground: root.foreground
                    }
                    SoundRow {
                        objectName: "sound:" + entry.modelData.key
                        picked: root.settings.sound === entry.modelData.key
                        name: entry.modelData.name
                        detail: entry.modelData.length
                        onChosen: root.save({ sound: entry.modelData.key })

                        PlayButton { key: entry.modelData.key; name: entry.modelData.name }
                    }
                }
            }

            PanelSeparator {
                Layout.fillWidth: true
                foreground: root.foreground
            }
            SoundRow {
                objectName: "sound:custom"
                picked: root.settings.sound === Sound.CUSTOM && root.hasCustomFile
                name: root.hasCustomFile ? Sound.nameOf(Sound.CUSTOM, root.settings) : "Custom file…"
                detail: root.hasCustomFile ? "" : "mp3, ogg, wav"
                onChosen: root.hasCustomFile ? root.save({ sound: Sound.CUSTOM }) : root.chooseFile()

                PlayButton {
                    visible: root.hasCustomFile
                    key: Sound.CUSTOM
                    name: "custom file"
                }
                ActionButton {
                    Layout.preferredWidth: Style.spacing.controlHeight
                    horizontalPadding: 0
                    iconText: Icons.folder
                    tooltipText: "Choose a file"
                    foreground: Util.alpha(root.foreground, Tone.secondary)
                    onClicked: root.chooseFile()
                }
            }
        }
    }

    SettingRow {
        Layout.fillWidth: true
        label: "Volume"
        foreground: root.foreground
        enabled: root.soundOn
        opacity: root.soundOn ? 1 : Tone.muted

        PanelSlider {
            id: volume
            Layout.preferredWidth: Style.space(110)
            bar: root.bar
            value: root.settings.volume
            minimum: 0
            maximum: 100
            step: 5
            integer: true
            trackColor: Style.selectedFillFor(root.foreground, Color.accent)
            fillColor: root.foreground
            knobColor: root.foreground
            onReleased: function(v) { root.save({ volume: Math.round(v) }) }
        }
        Text {
            textFormat: Text.PlainText
            Layout.preferredWidth: Style.space(38)
            horizontalAlignment: Text.AlignRight
            text: Math.round(volume.liveValue) + "%"
            color: Util.alpha(root.foreground, Tone.secondary)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
        }
        ActionButton {
            bordered: true
            iconText: root.previewKey !== "" ? Icons.stop : Icons.play
            text: root.previewKey !== "" ? "Stop" : "Test"
            tooltipText: root.service ? "" : root.noService
            foreground: root.service ? root.foreground : Util.alpha(root.foreground, Tone.muted)
            onClicked: root.test()
        }
    }

    Item { Layout.fillHeight: true }
}
