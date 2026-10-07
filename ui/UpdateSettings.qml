pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Icons.js" as Icons
import "Settings.js" as Settings

// The Updates page: the installed version and the commands that update the
// plugin through Omarchy (ADR-0021). The plugin never fetches or pulls by
// itself.
ColumnLayout {
    id: root

    property string version: ""
    property var toast: null
    property color foreground: Color.foreground

    function copyCommand() {
        Quickshell.clipboardText = Settings.updateCommandLine()
        if (root.toast) root.toast.show("Copied. Paste it in a terminal.")
    }

    spacing: Style.spacing.lg

    SettingRow {
        Layout.fillWidth: true
        label: "Version"
        caption: root.version !== "" ? root.version : "manifest.json not found"
        foreground: root.foreground
    }

    SettingRow {
        Layout.fillWidth: true
        label: "Update"
        caption: "Run in a terminal. Omarchy shows the changes and asks before it pulls. The restart loads the new version."
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

    SettingRow {
        Layout.fillWidth: true
        label: "Listing"
        caption: "Omanotes on omarchyplugins.com."
        foreground: root.foreground

        ActionButton {
            bordered: true
            iconText: Icons.openInNew
            text: "Open"
            foreground: root.foreground
            onClicked: Util.execArgv(["xdg-open", Settings.LISTING_URL])
        }
    }

    Item { Layout.fillHeight: true }
}
