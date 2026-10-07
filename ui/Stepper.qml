import QtQuick
import QtQuick.Layouts
import qs.Commons
import "Icons.js" as Icons
import "Tone.js" as Tone

// Minus, the value, plus: a whole number picked with the mouse (ADR-0013),
// one step per click, never past its range. Each click is a change, so the
// owner saves it at once and nothing waits for the user to leave.
RowLayout {
    id: root

    property int value: 0
    property int minimum: 0
    property int maximum: 100
    property string unit: ""
    property color foreground: Color.foreground

    signal stepped(int value)

    spacing: 0
    implicitHeight: Style.spacing.controlHeight

    ActionButton {
        bordered: true
        horizontalPadding: Style.spacing.sm
        iconText: Icons.minus
        tooltipText: root.value > root.minimum ? "" : "Lowest is " + root.minimum + " " + root.unit
        foreground: root.value > root.minimum ? root.foreground : Util.alpha(root.foreground, Tone.muted)
        onClicked: if (root.value > root.minimum) root.stepped(root.value - 1)
    }

    Rectangle {
        Layout.preferredWidth: Style.space(64)
        Layout.preferredHeight: Style.spacing.controlHeight
        Layout.leftMargin: -1
        Layout.rightMargin: -1
        color: "transparent"
        border.width: Style.normalBorderWidth
        border.color: Style.normalBorderFor(root.foreground, Color.accent)

        Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: root.value + (root.unit !== "" ? " " + root.unit : "")
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
        }
    }

    ActionButton {
        bordered: true
        horizontalPadding: Style.spacing.sm
        iconText: Icons.plus
        tooltipText: root.value < root.maximum ? "" : "Highest is " + root.maximum + " " + root.unit
        foreground: root.value < root.maximum ? root.foreground : Util.alpha(root.foreground, Tone.muted)
        onClicked: if (root.value < root.maximum) root.stepped(root.value + 1)
    }
}
