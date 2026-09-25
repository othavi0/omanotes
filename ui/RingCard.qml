import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Icons.js" as Icons
import "Tone.js" as Tone

// The card that drops under the bar while an alarm rings (prototype
// "Ringing · card"): bell and clock in the urgent colour, the title, the
// detail line, a meter that fills over the ring length, Snooze and Stop.
// Mouse only: the window it sits in takes no focus (ADR-0013).
BorderSurface {
    id: root

    property QtObject service: null
    readonly property var view: root.service ? root.service.ringView : null

    width: Style.space(380)
    implicitHeight: column.implicitHeight + 2 * Style.space(16)
    color: Color.popups.background
    // The theme's popup border colour would win over a surfaceSpec fallback;
    // the local colour differs from it, so the border is the urgent colour.
    borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.urgent, Color.popups.border, 1)
    radius: Style.cornerRadius

    ColumnLayout {
        id: column
        anchors.fill: parent
        anchors.margins: Style.space(16)
        spacing: Style.space(12)

        Row {
            spacing: Style.space(12)

            Text {
                text: Icons.bell
                color: Color.urgent
                font.family: Style.font.family
                font.pixelSize: Style.space(30)
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: root.view ? root.view.clock : ""
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.space(30)
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        Column {
            Layout.fillWidth: true
            spacing: Style.spacing.xs

            Text {
                width: parent.width
                text: root.view ? root.view.title : ""
                elide: Text.ElideRight
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
            }
            Text {
                width: parent.width
                text: root.view ? root.view.subtitle : ""
                elide: Text.ElideRight
                color: Util.alpha(Color.popups.text, Tone.secondary)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
            }
        }

        Rectangle {
            Layout.fillWidth: true
            height: Style.space(3)
            color: Util.alpha(Color.urgent, Style.selectedFillAlpha)

            Rectangle {
                objectName: "ringMeter"
                width: parent.width * (root.view ? root.view.progress : 0)
                height: parent.height
                color: Color.urgent
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.lg

            ActionButton {
                Layout.fillWidth: true
                bordered: true
                iconText: Icons.snooze
                text: root.view ? root.view.snoozeLabel : "Snooze"
                foreground: Color.urgent
                onClicked: if (root.service) root.service.snooze()
            }
            ActionButton {
                Layout.fillWidth: true
                bordered: true
                selected: true
                iconText: Icons.stop
                text: "Stop"
                foreground: Color.popups.text
                onClicked: if (root.service) root.service.stop()
            }
        }
    }
}
