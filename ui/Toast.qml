import QtQuick
import qs.Commons
import qs.Ui

Item {
    id: root

    property string text: ""
    property bool urgent: false

    // Sizing is internal (it floats over the panel, not in a layout).
    width: box.implicitWidth
    height: box.implicitHeight

    function show(message, urgent) {
        root.text = String(message || "")
        root.urgent = urgent === true
        hideTimer.restart()
        opacity = 1
    }
    function hide() {
        opacity = 0
    }

    opacity: 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

    Timer {
        id: hideTimer
        interval: 2200
        onTriggered: root.hide()
    }

    BorderSurface {
        id: box
        anchors.fill: parent
        color: Util.alpha(Color.popups.background, 0.96)
        borderSpec: Border.surfaceSpec("popups", "border",
            root.urgent ? Color.urgent : Color.popups.border, 1)
        radius: Style.cornerRadius

        implicitWidth: label.implicitWidth + Style.space(28)
        implicitHeight: label.implicitHeight + Style.space(14)

        Text {
            id: label
            anchors.centerIn: parent
            text: root.text
            color: root.urgent ? Color.urgent : Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            maximumLineCount: 3
        }
    }
}