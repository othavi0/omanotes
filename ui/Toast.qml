import QtQuick
import qs.Commons
import qs.Ui

// A transient line over the bottom of the panel: show(message[, urgent])
// fades it in and it hides itself after a moment. The parent positions it;
// the toast sizes itself and wraps to stay inside the parent's width.
Item {
    id: root

    property string text: ""
    property bool urgent: false

    readonly property real padX: Style.space(14)
    readonly property real padY: Style.space(7)
    readonly property real maxWidth: parent ? parent.width - 2 * Style.spacing.panelPadding : 0

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
        color: Color.popups.background
        borderSpec: Border.surfaceSpec("popups", "border",
            root.urgent ? Color.urgent : Color.popups.border, 1)
        radius: Style.cornerRadius

        implicitWidth: label.width + 2 * root.padX
        implicitHeight: label.height + 2 * root.padY

        Text {
            id: label
            anchors.centerIn: parent
            width: Math.min(implicitWidth, root.maxWidth - 2 * root.padX)
            text: root.text
            color: root.urgent ? Color.urgent : Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            maximumLineCount: 3
            elide: Text.ElideRight
        }
    }
}
