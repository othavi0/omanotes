pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Icons.js" as Icons
import "Settings.js" as Settings
import "Tone.js" as Tone

// The Updates page: the version, what the last check or update found, and
// the daily check. The Updater hides git, the lock, the state file and the
// reload; this page only draws its view.
ColumnLayout {
    id: root

    property QtObject updater: null
    property var settings: ({})
    property var toast: null
    property color foreground: Color.foreground

    signal save(var patch)

    readonly property var view: root.updater ? root.updater.view : ({ phase: "loading", commits: [], behind: 0 })
    readonly property bool blocked: !!root.updater && root.updater.blocked
    readonly property var local: root.updater ? root.updater.local : null
    readonly property bool restartFailed: root.view.phase === "updated" && root.view.error === "restartFailed"
    readonly property bool good: root.view.phase === "upToDate" || (root.view.phase === "updated" && !root.restartFailed)
    readonly property bool bad: root.view.phase === "blocked" || root.view.phase === "offline" || root.view.phase === "failed" || root.restartFailed

    // Only the page whose click it was says what went wrong: the service's
    // Updater serves every monitor's panel.
    Connections {
        target: root.updater
        function onFailed(message, caller) { if (caller === root && root.toast) root.toast.show(message, true) }
    }

    function update() {
        if (!root.updater) return
        var error = root.updater.apply(root)
        if (error !== "" && root.toast) root.toast.show(error)
    }

    spacing: Style.spacing.lg

    SettingRow {
        Layout.fillWidth: true
        label: "Version"
        caption: Settings.versionText(root.local)
        foreground: root.foreground
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: status.implicitHeight + 2 * Style.spacing.lg
        radius: Style.cornerRadius
        color: "transparent"
        border.width: Style.normalBorderWidth
        border.color: Style.normalBorderFor(root.foreground, Color.accent)

        ColumnLayout {
            id: status
            anchors.fill: parent
            anchors.margins: Style.spacing.lg
            spacing: Style.spacing.md

            RowLayout {
                Layout.fillWidth: true
                spacing: Style.spacing.md

                Text {
                    visible: text !== ""
                    text: root.good ? Icons.checkCircle : root.bad ? Icons.alertCircle
                        : root.view.phase === "available" ? Icons.arrowDown : ""
                    color: root.bad ? Color.urgent : Color.accent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.icon
                }
                Text {
                    objectName: "updateHeadline"
                    Layout.fillWidth: true
                    text: Settings.updateHeadline(root.view, root.local)
                    wrapMode: Text.WordWrap
                    color: root.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                }
            }

            Repeater {
                model: root.view.phase === "available" || root.view.phase === "blocked" ? root.view.commits.slice(0, 4) : []
                delegate: RowLayout {
                    id: commit
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: Style.spacing.md
                    Text {
                        text: Settings.shortHash(commit.modelData.hash)
                        color: Color.accent
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                    }
                    Text {
                        Layout.fillWidth: true
                        text: commit.modelData.subject
                        elide: Text.ElideRight
                        color: Util.alpha(root.foreground, Tone.secondary)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                    }
                }
            }
            Text {
                visible: (root.view.phase === "available" || root.view.phase === "blocked") && root.view.behind > 4
                text: "and " + (root.view.behind - 4) + " more"
                color: Util.alpha(root.foreground, Tone.muted)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
            }

            Repeater {
                model: root.view.phase === "updating" ? Settings.updateSteps(root.view) : []
                delegate: Text {
                    required property var modelData
                    text: (modelData.state === "done" ? Icons.check : modelData.state === "now" ? Icons.loading : Icons.circleSmall) + "  " + modelData.label
                    color: modelData.state === "now" ? root.foreground
                        : Util.alpha(root.foreground, modelData.state === "done" ? Tone.secondary : Tone.muted)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: root.view.phase !== "none" && root.view.phase !== "loading" && root.view.phase !== "updating"
                spacing: Style.spacing.sm

                Text {
                    Layout.fillWidth: true
                    text: root.view.phase === "available"
                        ? (root.blocked ? "An alarm is ringing. Update after it stops." : "Validates, pulls with --ff-only and restarts the shell. Notes stay.")
                        : root.view.phase === "checking" ? "" : Settings.checkedAgoText(root.view.at, root.updater ? root.updater.nowMs : 0)
                    wrapMode: Text.WordWrap
                    color: Util.alpha(root.foreground, Tone.secondary)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                }
                ActionButton {
                    visible: root.view.phase === "blocked" && root.view.error === "dirty"
                    bordered: true
                    iconText: Icons.folder
                    text: "Open folder"
                    foreground: root.foreground
                    onClicked: if (root.updater) Util.execArgv(["xdg-open", root.updater.pluginDir])
                }
                ActionButton {
                    visible: root.view.phase !== "available"
                    bordered: true
                    iconText: Icons.refresh
                    text: root.view.phase === "offline" ? "Try again" : root.view.phase === "unchecked" ? "Check for updates" : "Check again"
                    foreground: root.view.canCheck ? root.foreground : Util.alpha(root.foreground, Tone.muted)
                    onClicked: if (root.updater) root.updater.check(root)
                }
                ActionButton {
                    visible: root.view.phase === "available"
                    bordered: true
                    selected: !root.blocked
                    iconText: Icons.download
                    text: "Update"
                    tooltipText: root.blocked ? "An alarm is ringing" : ""
                    foreground: root.blocked ? Util.alpha(root.foreground, Tone.muted) : root.foreground
                    onClicked: root.update()
                }
            }
        }
    }

    SettingRow {
        Layout.fillWidth: true
        label: "Check daily"
        caption: "Marks the gear with a dot when origin/main has new commits."
        foreground: root.foreground

        Segment {
            objectName: "checkDaily"
            fill: false
            options: [{ value: "on", label: "On" }, { value: "off", label: "Off" }]
            value: root.settings.checkUpdates ? "on" : "off"
            foreground: root.foreground
            onPicked: function(v) { root.save({ checkUpdates: v === "on" }) }
        }
    }

    Item { Layout.fillHeight: true }
}
