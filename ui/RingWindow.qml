import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons

// The ring card's window, one per screen: a passive overlay like the
// notifications popups. It takes no keyboard focus and handles no key
// (ADR-0013), ignores exclusion zones, and is click-through outside the card.
PanelWindow {
    id: win

    required property var modelData
    // The service that created this window, found by walking up from the
    // Variants that holds it, so the Component needs no closure over it.
    readonly property QtObject service: win.parent && "ringView" in win.parent ? win.parent : null

    screen: modelData
    WlrLayershell.namespace: "omanotes-ring"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    mask: Region { item: card }

    // Centred under a top bar, above a bottom bar, in the top corner beside
    // a side bar, always the bar's clearance away from it.
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
