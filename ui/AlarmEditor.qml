pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "../data/Alarm.js" as Alarm
import "Alarms.js" as Alarms
import "Icons.js" as Icons
import "Tone.js" as Tone

// Owns the alarm edit session, as EditorPane does for items: which alarm
// the controls belong to, what they opened with and what they hold now. The
// tab decides when to commit; `fields` is what it commits, or null while
// the time does not parse.
ColumnLayout {
    id: root

    property var alarm: null
    property bool draft: false
    property bool deleteArmed: false
    property double nowMs: 0
    property color foreground: Color.foreground

    property int editingId: -1
    property alias timeText: timeField.text
    property alias labelText: labelField.text
    property var days: []
    property alias snoozeText: snoozeField.text
    property alias ringText: ringField.text
    property string _base: ""

    readonly property string _current: JSON.stringify([root.timeText, root.labelText, root.days, root.snoozeText, root.ringText])
    readonly property bool dirty: root.editingId >= 0 && root._current !== root._base
    readonly property bool unsaved: root.draft || root.dirty
    readonly property bool fieldFocused: timeField.inputFocused || labelField.activeFocus || snoozeField.activeFocus || ringField.activeFocus
    readonly property var fields: Alarm.parseFields({ time: root.timeText, label: root.labelText, days: root.days,
        snoozeMinutes: root.snoozeText, ringMinutes: root.ringText })
    readonly property bool on: !!root.alarm && Alarm.isOn(root.alarm, root.nowMs)
    // When the alarm as edited rings next, for the line beside the time.
    readonly property real nextAt: root.fields
        ? Alarm.alarmNextAt(root.draft || !root.alarm ? Alarm.newAlarm(root.fields, root.nowMs)
            : Alarm.withPatch(root.alarm, Alarm.editPatch(root.alarm, root.fields, root.nowMs)), root.nowMs)
        : 0

    signal edited()
    signal newRequested()
    signal deleteClicked()
    signal saveRequested()
    signal discardRequested()

    function openAlarm(a) {
        root.editingId = a ? Number(a.id) : -1
        timeField.text = a ? Alarms.timeText(a.hour, a.minute) : ""
        labelField.text = a ? String(a.label || "") : ""
        root.days = a ? a.days.slice() : []
        snoozeField.text = String(a ? a.snoozeMinutes : Alarm.DEFAULT_SNOOZE_MINUTES)
        ringField.text = String(a ? a.ringMinutes : Alarm.DEFAULT_RING_MINUTES)
        root._base = root._current
    }
    function openDraft() { root.openAlarm(null) }
    // Opens a draft holding the fields a failed insert carried.
    function reopenDraft(record) {
        root.openAlarm(null)
        timeField.text = Alarms.timeText(record.hour, record.minute)
        labelField.text = record.label
        root.days = record.days.slice()
        snoozeField.text = String(record.snoozeMinutes)
        ringField.text = String(record.ringMinutes)
    }
    // Marks what the controls hold as saved.
    function markSaved() { root._base = root._current }
    function focusTime() { timeField.focusInput() }

    function toggleDay(day) {
        var list = root.days.slice()
        var at = list.indexOf(day)
        if (at >= 0) list.splice(at, 1)
        else list.push(day)
        root.days = Alarm.normalizeDays(list)
        root.edited()
    }

    spacing: Style.spacing.lg

    RowLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.md

        Text {
            text: Icons.alarm
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.icon
        }
        Text {
            text: root.draft ? "New alarm" : "Alarm"
            color: root.foreground
            font.bold: true
            font.family: Style.font.family
            font.pixelSize: Style.font.body
        }
        Rectangle {
            visible: !root.draft
            width: stateText.implicitWidth + Style.space(14)
            height: stateText.implicitHeight + Style.space(6)
            radius: height / 2
            color: root.on ? Util.alpha(Color.accent, Style.selectedFillAlpha) : Util.alpha(root.foreground, Style.hoverFillAlpha)
            Text {
                id: stateText
                anchors.centerIn: parent
                text: root.on ? "on" : "off"
                color: root.on ? Color.accent : Util.alpha(root.foreground, Tone.secondary)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
            }
        }

        Item { Layout.fillWidth: true }

        Row {
            spacing: Style.spacing.sm
            Rectangle {
                width: Style.space(6); height: width; radius: width / 2
                anchors.verticalCenter: parent.verticalCenter
                color: root.unsaved ? Color.urgent : Util.alpha(root.foreground, Tone.muted)
            }
            Text {
                text: root.draft ? "Unsaved draft" : (root.dirty ? "Unsaved changes" : "Saved")
                color: Util.alpha(root.foreground, Tone.secondary)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(14)

        TimeField {
            id: timeField
            foreground: root.foreground
            onAccepted: labelField.forceActiveFocus()
        }
        Text {
            Layout.fillWidth: true
            text: root.fields ? Alarms.nextInText(root.nextAt, root.nowMs) : (root.timeText === "" ? "" : "Needs a time like 07:30")
            elide: Text.ElideRight
            color: root.fields ? Util.alpha(root.foreground, Tone.secondary) : Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.body
        }
    }

    component Key: Text {
        Layout.preferredWidth: Style.space(64)
        color: Util.alpha(root.foreground, Tone.secondary)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
    }

    component MinutesField: Field {
        Layout.preferredWidth: Style.space(70)
        foreground: root.foreground
        activeFocusOnTab: false
        rightPadding: Style.space(34)
        validator: IntValidator { bottom: 1; top: 180 }
        Text {
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.controlPaddingX
            anchors.verticalCenter: parent.verticalCenter
            text: "min"
            color: Util.alpha(root.foreground, Tone.secondary)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(12)

        Key { text: "Label" }
        Field {
            id: labelField
            Layout.fillWidth: true
            placeholderText: "Wake up"
            maximumLength: Alarm.MAX_LABEL
            foreground: root.foreground
            activeFocusOnTab: false
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(12)

        Key { text: "Repeat" }
        Row {
            spacing: Style.spacing.xs
            Repeater {
                model: Alarms.WEEK_ORDER
                delegate: ActionButton {
                    required property int modelData
                    required property int index
                    objectName: "dayChip"
                    horizontalPadding: Style.space(8)
                    bordered: true
                    selected: root.days.indexOf(modelData) >= 0
                    text: Alarms.DAY_LETTERS[index]
                    foreground: root.foreground
                    onClicked: root.toggleDay(modelData)
                }
            }
        }
        Text {
            Layout.fillWidth: true
            text: Alarms.daysText(root.days)
            elide: Text.ElideRight
            color: Util.alpha(root.foreground, Tone.secondary)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(12)

        Key { text: "Snooze" }
        MinutesField { id: snoozeField }
        Key {
            Layout.preferredWidth: -1
            text: "Ring"
        }
        MinutesField {
            id: ringField
            validator: IntValidator { bottom: 1; top: 60 }
        }
        Item { Layout.fillWidth: true }
    }

    Item { Layout.fillHeight: true }

    RowLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.md

        ActionButton {
            visible: !root.draft
            bordered: true
            iconText: Icons.plus
            text: "Alarm"
            foreground: root.foreground
            onClicked: root.newRequested()
        }
        ActionButton {
            visible: root.draft
            bordered: true
            selected: true
            iconText: Icons.check
            text: "Save alarm"
            foreground: root.foreground
            onClicked: root.saveRequested()
        }
        ActionButton {
            visible: root.draft
            bordered: true
            text: "Discard"
            foreground: root.foreground
            onClicked: root.discardRequested()
        }
        Item { Layout.fillWidth: true }
        ActionButton {
            visible: !root.draft
            bordered: true
            iconText: Icons.trash
            text: root.deleteArmed ? "Confirm" : "Delete"
            foreground: Color.urgent
            onClicked: root.deleteClicked()
        }
    }
}
