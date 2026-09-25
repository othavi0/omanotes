import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons

PanelWindow {
    id: win

    required property var modelData
    property QtObject service: null

    screen: modelData
    WlrLayershell.namespace: "omanotes-ring"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    mask: Region { item: card }

    RingCard {
        id: card
        readonly property string position: win.service ? win.service.barPosition : "top"
        readonly property int clearance: win.service ? win.service.barClearance : 0
        service: win.service
        anchors.horizontalCenter: card.position === "left" || card.position === "right" ? undefined : parent.horizontalCenter
        anchors.top: card.position === "bottom" ? undefined : parent.top
        anchors.bottom: card.position === "bottom" ? parent.bottom : undefined
        anchors.left: card.position === "left" ? parent.left : undefined
        anchors.right: card.position === "right" ? parent.right : undefined
        anchors.topMargin: card.position === "top" ? card.clearance : Style.gapsOut
        anchors.bottomMargin: card.clearance
        anchors.leftMargin: card.clearance
        anchors.rightMargin: card.clearance
    }
}
