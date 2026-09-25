import QtQuick
import qs.Commons
import "Tone.js" as Tone

// One `key` + label pair inside a HintBar.
Row {
    id: root
    property string k: ""
    property string l: ""
    property color foreground: Color.foreground
    spacing: Style.spacing.sm

    Rectangle {
        width: kt.implicitWidth + Style.space(10)
        height: kt.implicitHeight + Style.space(4)
        radius: Style.cornerRadius
        color: Style.normalFillFor(root.foreground, Color.accent)
        border.width: Style.normalBorderWidth
        border.color: Style.normalBorderFor(root.foreground, Color.accent)
        Text {
            id: kt
            anchors.centerIn: parent
            text: root.k
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
        }
    }
    Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.l
        color: Util.alpha(root.foreground, Tone.secondary)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
    }
}
