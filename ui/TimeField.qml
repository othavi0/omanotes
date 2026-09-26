import QtQuick
import qs.Commons
import "Tone.js" as Tone

// Like the editor body, it is not a Field: it draws the kit's control fill and
// border itself and takes the height its digits need, the one single-line
// exception to ADR-0008. The text is whatever the user typed; the editor
// parses it with Alarm.parseTime.
Rectangle {
    id: root

    property alias text: input.text
    property color foreground: Color.foreground
    readonly property bool inputFocused: input.activeFocus

    signal accepted()

    function focusInput() { input.forceActiveFocus() }

    implicitWidth: Style.space(150)
    implicitHeight: input.implicitHeight + 2 * Style.space(4)
    radius: Style.cornerRadius
    color: Style.controlFill(input.activeFocus, hover.hovered, root.foreground, Color.accent)
    border.width: Style.controlBorderWidth(input.activeFocus, hover.hovered)
    border.color: Style.controlBorder(input.activeFocus, hover.hovered, root.foreground, Color.accent)

    HoverHandler { id: hover }

    TextInput {
        id: input
        anchors.fill: parent
        anchors.leftMargin: Style.space(14)
        anchors.rightMargin: Style.space(14)
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: TextInput.AlignHCenter
        color: root.foreground
        selectionColor: Style.selectionFillFor(root.foreground, Color.accent)
        selectedTextColor: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.space(44)
        font.bold: true
        font.letterSpacing: -Style.spaceReal(1)
        inputMethodHints: Qt.ImhTime
        validator: RegularExpressionValidator { regularExpression: /\d{0,2}:?\d{0,2}/ }
        selectByMouse: true
        activeFocusOnTab: false
        onAccepted: root.accepted()

        Text {
            anchors.centerIn: parent
            visible: input.text === "" && !input.activeFocus
            text: "00:00"
            color: Util.alpha(root.foreground, Tone.muted)
            font: input.font
        }
    }
}
