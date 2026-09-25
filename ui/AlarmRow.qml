import QtQuick
import qs.Commons
import qs.Ui
import "Alarms.js" as Alarms
import "Tone.js" as Tone

// One row of the Alarms list (prototype C): the time in large digits, the
// label with the days and state under it, and the switch. An alarm that is
// off is dimmed. Clicking the row selects it; the switch toggles it.
Rectangle {
    id: root

    property var alarm: ({})
    property bool selected: false
    property bool on: true
    property double nowMs: 0
    property color foreground: Color.foreground

    signal picked()
    signal toggled()

    readonly property color textColor: root.on
        ? (root.selected ? Style.selectedStateColor(root.foreground, Color.accent) : root.foreground)
        : Util.alpha(root.foreground, Tone.muted)

    height: Style.space(54)
    radius: Style.cornerRadius
    color: root.selected
        ? Style.selectedFillFor(root.foreground, Color.accent)
        : (rowMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent")

    MouseArea {
        id: rowMouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.picked()
    }

    Text {
        id: clock
        x: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(74)
        text: Alarms.timeText(root.alarm.hour, root.alarm.minute)
        color: root.textColor
        font.family: Style.font.family
        font.pixelSize: Style.space(22)
        font.bold: true
    }

    Column {
        anchors.left: clock.right
        anchors.right: toggle.left
        anchors.rightMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xxs

        Text {
            width: parent.width
            text: root.alarm.label !== "" ? root.alarm.label : Alarms.timeText(root.alarm.hour, root.alarm.minute)
            elide: Text.ElideRight
            color: root.textColor
            font.family: Style.font.family
            font.pixelSize: Style.font.body
        }
        Text {
            width: parent.width
            text: Alarms.rowDetail(root.alarm, root.nowMs)
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            color: Util.alpha(root.foreground, Tone.secondary)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
        }
    }

    ToggleSwitch {
        id: toggle
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        checked: root.on
        cursorRing: false
        foreground: root.foreground
        onToggled: root.toggled()
    }
}
