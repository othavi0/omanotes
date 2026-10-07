pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Icons.js" as Icons
import "Settings.js" as Settings
import "Tone.js" as Tone

// The Updates page: the version of the code that runs and the commands that
// update the plugin through Omarchy (ADR-0021). The plugin never fetches or
// pulls by itself.
ColumnLayout {
    id: root

    property var toast: null
    property color foreground: Color.foreground
    // A test points it at a stub.
    property string wlCopyPath: "/usr/bin/wl-copy"

    function say(text, urgent) {
        if (root.toast) root.toast.show(text, urgent)
    }

    // The text goes on wl-copy's stdin, the way the shell's own panels copy:
    // Quickshell's clipboard only takes on Wayland while one of its windows
    // has the keyboard.
    function copyCommand() {
        if (clipboard.running) return
        clipboard.began = false
        clipboard.stdinEnabled = true
        clipboard.running = true
    }

    Process {
        id: clipboard
        property bool began: false
        command: [root.wlCopyPath]
        clearEnvironment: true
        // null passes the shell's own value (Quickshell 0.3.1).
        environment: ({ WAYLAND_DISPLAY: null, XDG_RUNTIME_DIR: null })
        stdout: StdioCollector { waitForEnd: true }
        stderr: StdioCollector { id: copyError; waitForEnd: true }
        onStarted: {
            clipboard.began = true
            clipboard.write(Settings.UPDATE_COMMAND)
            clipboard.stdinEnabled = false
        }
        onExited: function(exitCode) {
            if (exitCode === 0) root.say(Settings.COPIED_TEXT, false)
            else root.say(Settings.copyFailedText(exitCode, copyError.text, root.wlCopyPath), true)
        }
        onRunningChanged: if (!clipboard.running && !clipboard.began) root.say(Settings.copyFailedText(null, "", root.wlCopyPath), true)
    }

    spacing: Style.spacing.lg

    SettingRow {
        Layout.fillWidth: true
        label: "Version"
        caption: Settings.VERSION
        foreground: root.foreground
    }

    SettingRow {
        Layout.fillWidth: true
        label: "Update"
        caption: Settings.UPDATE_CAPTION
        foreground: root.foreground

        ActionButton {
            objectName: "copyUpdate"
            bordered: true
            iconText: Icons.copy
            text: "Copy"
            foreground: root.foreground
            onClicked: root.copyCommand()
        }
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: commands.implicitHeight + 2 * Style.spacing.lg
        radius: Style.cornerRadius
        color: "transparent"
        border.width: Style.normalBorderWidth
        border.color: Style.normalBorderFor(root.foreground, Color.accent)

        ColumnLayout {
            id: commands
            anchors.fill: parent
            anchors.margins: Style.spacing.lg
            spacing: Style.spacing.sm

            Repeater {
                model: Settings.UPDATE_COMMANDS
                delegate: Text {
                    required property string modelData
                    Layout.fillWidth: true
                    objectName: "updateCommand"
                    text: modelData
                    textFormat: Text.PlainText
                    wrapMode: Text.WrapAnywhere
                    color: root.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                }
            }
        }
    }

    Text {
        Layout.fillWidth: true
        objectName: "restartNote"
        text: Settings.RESTART_NOTE
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Util.alpha(root.foreground, Tone.secondary)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
    }

    Item { Layout.fillHeight: true }
}
