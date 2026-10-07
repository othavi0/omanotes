import QtQuick
import QtQuick.Layouts
import qs.Commons
import "Tone.js" as Tone

// One setting: its name, a faded caption under it and, on the right, the
// controls it holds.
RowLayout {
    id: root

    property string label: ""
    property string caption: ""
    property color foreground: Color.foreground
    default property alias controls: slot.data

    spacing: Style.spacing.xxl

    ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.xxs

        Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: root.label
            elide: Text.ElideRight
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
        }
        Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            visible: root.caption !== ""
            text: root.caption
            wrapMode: Text.WordWrap
            color: Util.alpha(root.foreground, Tone.secondary)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
        }
    }

    RowLayout {
        id: slot
        Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
        spacing: Style.spacing.sm
    }
}
