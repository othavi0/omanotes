pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Mutually exclusive segmented control: the panel's tabs, the
// All/Notes/Todos filter, the draft's Note/Todo picker and the On/Off
// choices of Settings. Each chip is pinned to Style.spacing.controlHeight,
// like ActionButton and Field. An option may carry an icon, a count, a
// tooltip and a dot; an empty label leaves the icon alone.
RowLayout {
    id: root

    property var options: []
    property string value: ""
    property bool fill: true
    property color foreground: Color.foreground

    signal picked(string v)

    spacing: 0
    uniformCellSizes: root.fill

    Repeater {
        model: root.options

        delegate: Rectangle {
            id: chip
            required property var modelData
            required property int index
            readonly property bool on: modelData.value === root.value

            Layout.fillWidth: root.fill
            Layout.leftMargin: index === 0 ? 0 : -1
            implicitWidth: inner.implicitWidth + Style.space(22)
            implicitHeight: Style.spacing.controlHeight
            color: on ? Style.selectedFillFor(root.foreground, Color.accent) : (ma.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent")
            border.width: 1
            border.color: on ? Util.alpha(root.foreground, 0.55) : Style.normalBorderFor(root.foreground, Color.accent)
            z: on ? 1 : 0

            Row {
                id: inner
                anchors.centerIn: parent
                spacing: Style.spacing.md

                Text {
                    visible: !!chip.modelData.icon
                    text: chip.modelData.icon || ""
                    color: root.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.icon
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    visible: chip.modelData.label !== ""
                    text: chip.modelData.label
                    color: root.foreground
                    font.bold: chip.on
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    visible: chip.modelData.count !== undefined
                    text: chip.modelData.count === undefined ? "" : String(chip.modelData.count)
                    color: Util.alpha(root.foreground, 0.55)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            // Marks an option that wants a look, such as Settings with an
            // update waiting.
            Rectangle {
                visible: !!chip.modelData.dot
                width: Style.space(7)
                height: width
                radius: width / 2
                color: Color.urgent
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: Style.space(4)
            }

            MouseArea {
                id: ma
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.picked(chip.modelData.value)
            }

            PanelToolTip {
                visible: !!chip.modelData.tooltip && ma.containsMouse
                text: chip.modelData.tooltip || ""
            }
        }
    }
}
