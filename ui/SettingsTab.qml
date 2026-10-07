pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "../data/Sound.js" as Sound
import "Icons.js" as Icons
import "Settings.js" as Settings
import "Tone.js" as Tone

// Settings tab: the sections on the left, drawn like the item list, and the
// chosen section's page on the right. The settings live in the widget's Db,
// so every page saves with or without the service (ADR-0016). A control
// saves on the click or release that changes it: there is no text to leave,
// so nothing waits for a commit (ADR-0007 is about the editors).
FocusScope {
    id: root

    property QtObject db: null
    property QtObject service: null
    property var toast: null
    property QtObject bar: null
    property color foreground: Color.foreground

    property string section: Settings.SECTIONS[0].id
    readonly property var settings: root.db ? root.db.settings : ({})
    // The ranges the Db accepts, so the steppers and their captions never
    // repeat them.
    readonly property var spec: root.db ? root.db.settingsSpec : null
    readonly property int sectionIndex: Math.max(0, root.sectionIds.indexOf(root.section))
    readonly property var info: ({
        sound: Sound.soundName(root.settings),
        bytes: root.db ? root.db.dbBytes : 0
    })
    readonly property var sectionIds: Settings.SECTIONS.map(function(s) { return s.id })
    readonly property var sectionIcons: ({ sound: Icons.volume, alarms: Icons.alarm, updates: Icons.update, history: Icons.history, data: Icons.database })

    // A refused or failed write reaches the toast through the Db's failed
    // signal, like every other write of the panel.
    function save(patch) {
        if (root.db) root.db.setSettings(patch)
    }

    function pickSection(id) {
        confirm.cancel()
        root.section = id
        focusSink.forceActiveFocus()
    }

    function resetFocus() {
        confirm.cancel()
        focusSink.forceActiveFocus()
    }

    // A Keep that would remove entries is armed like every destructive
    // button (Arm in CONTEXT.md); one that removes nothing saves at once.
    function pickKeep(days) {
        if (!root.db) return
        if (root.db.wouldPruneHistory(days) && !confirm.press("keep:" + days)) {
            if (root.toast) root.toast.show("Removes entries older than " + days + " days. Click again to confirm.")
            return
        }
        confirm.cancel()
        root.save({ historyDays: days })
    }

    ArmedConfirm { id: confirm }

    function backup() {
        if (root.db) root.db.backup()
    }

    Connections {
        target: root.db
        function onBackedUp(name) { if (root.toast) root.toast.show("Saved " + name) }
    }

    // Holds focus for the tab, so KeyboardPanel's focusTarget lands inside
    // it and Esc reaches Panel.qml.
    Item {
        id: focusSink
        anchors.fill: parent
        focus: true
    }

    RowLayout {
        anchors.fill: parent
        spacing: Style.spacing.xxl

        ListView {
            id: sectionList
            Layout.preferredWidth: Style.space(270)
            Layout.minimumWidth: Style.space(270)
            Layout.maximumWidth: Style.space(270)
            Layout.fillHeight: true
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            keyNavigationEnabled: false
            spacing: Style.spacing.xxs
            model: Settings.SECTIONS

            delegate: Rectangle {
                id: sectionRow
                required property var modelData
                readonly property bool selected: sectionRow.modelData.id === root.section
                objectName: "section:" + sectionRow.modelData.id
                width: sectionList.width
                height: Style.space(30)
                radius: Style.cornerRadius
                color: sectionRow.selected ? Style.selectedFillFor(root.foreground, Color.accent)
                    : sectionMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

                MouseArea {
                    id: sectionMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.pickSection(sectionRow.modelData.id)
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(10)
                    anchors.rightMargin: Style.space(10)
                    spacing: Style.space(9)

                    Text {
                        textFormat: Text.PlainText
                        text: root.sectionIcons[sectionRow.modelData.id] || ""
                        color: sectionRow.selected ? Style.selectedStateColor(root.foreground, Color.accent)
                            : Util.alpha(root.foreground, Tone.secondary)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.icon
                    }
                    Text {
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        text: sectionRow.modelData.label
                        elide: Text.ElideRight
                        color: sectionRow.selected ? Style.selectedStateColor(root.foreground, Color.accent) : root.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                    }
                    Text {
                        textFormat: Text.PlainText
                        text: Settings.sectionMeta(sectionRow.modelData.id, root.settings, root.info)
                        color: Util.alpha(root.foreground, Tone.secondary)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                    }
                }
            }
        }

        PanelSeparator {
            Layout.fillHeight: true
            Layout.preferredWidth: 1
            foreground: root.foreground
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Style.spacing.lg

            RowLayout {
                Layout.fillWidth: true
                spacing: Style.spacing.md

                Text {
                    textFormat: Text.PlainText
                    text: root.sectionIcons[root.section] || ""
                    color: Color.accent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.icon
                }
                Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: Settings.SECTIONS[root.sectionIndex].label
                    color: root.foreground
                    font.bold: true
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                }
            }

            StackLayout {
                id: pages
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: root.sectionIndex

                SoundSettings {
                    settings: root.settings
                    service: root.service
                    toast: root.toast
                    bar: root.bar
                    foreground: root.foreground
                    onSave: function(patch) { root.save(patch) }
                }

                ColumnLayout {
                    spacing: Style.spacing.lg

                    SettingRow {
                        Layout.fillWidth: true
                        label: "Snooze"
                        caption: Settings.snoozeCaption(root.spec)
                        foreground: root.foreground
                        Stepper {
                            objectName: "snooze"
                            value: root.settings.snoozeMinutes || 0
                            minimum: root.spec ? root.spec.snoozeMinutes.min : 0
                            maximum: root.spec ? root.spec.snoozeMinutes.max : 0
                            unit: "min"
                            foreground: root.foreground
                            onStepped: function(v) { root.save({ snoozeMinutes: v }) }
                        }
                    }
                    SettingRow {
                        Layout.fillWidth: true
                        label: "Ring for"
                        caption: Settings.ringCaption(root.spec)
                        foreground: root.foreground
                        Stepper {
                            objectName: "ring"
                            value: root.settings.ringMinutes || 0
                            minimum: root.spec ? root.spec.ringMinutes.min : 0
                            maximum: root.spec ? root.spec.ringMinutes.max : 0
                            unit: "min"
                            foreground: root.foreground
                            onStepped: function(v) { root.save({ ringMinutes: v }) }
                        }
                    }
                    Text {
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        text: "Applies to new alarms. Each alarm keeps its own values."
                        wrapMode: Text.WordWrap
                        color: Util.alpha(root.foreground, Tone.muted)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                    }
                    Item { Layout.fillHeight: true }
                }

                UpdateSettings {
                    objectName: "updatesPage"
                    toast: root.toast
                    foreground: root.foreground
                }

                ColumnLayout {
                    spacing: Style.spacing.lg

                    SettingRow {
                        Layout.fillWidth: true
                        label: "Keep entries"
                        caption: "Older entries are removed when the panel opens."
                        foreground: root.foreground
                        Segment {
                            objectName: "keep"
                            fill: false
                            options: Settings.KEEP_CHOICES.map(function(c) {
                                return { value: String(c.value), label: confirm.isArmedFor("keep:" + c.value) ? "Confirm" : c.label }
                            })
                            value: String(root.settings.historyDays)
                            foreground: root.foreground
                            onPicked: function(v) { root.pickKeep(Number(v)) }
                        }
                    }
                    Item { Layout.fillHeight: true }
                }

                ColumnLayout {
                    spacing: Style.spacing.lg

                    SettingRow {
                        Layout.fillWidth: true
                        label: "Database"
                        caption: root.db ? Settings.pathText(root.db.dbPath, Quickshell.env("HOME")) + " · " + Settings.sizeText(root.db.dbBytes) : ""
                        foreground: root.foreground
                    }
                    SettingRow {
                        Layout.fillWidth: true
                        label: "Backup"
                        caption: "Copies the database next to it with today's date."
                        foreground: root.foreground
                        ActionButton {
                            bordered: true
                            iconText: Icons.save
                            text: "Back up now"
                            foreground: root.foreground
                            onClicked: root.backup()
                        }
                        ActionButton {
                            bordered: true
                            iconText: Icons.folder
                            text: "Open folder"
                            foreground: root.foreground
                            onClicked: if (root.db) Quickshell.execDetached(["/usr/bin/xdg-open", root.db.dataDir])
                        }
                    }
                    Item { Layout.fillHeight: true }
                }
            }
        }
    }

    Component.onCompleted: focusSink.forceActiveFocus()
}
