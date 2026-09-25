import QtQuick
import qs.Commons
import "Item.js" as ItemJs
import "Icons.js" as Icons
import "Tone.js" as Tone

// One row of the unified list: a checkbox (todo) or note glyph, an unread
// dot on unread notes, the title (bold when an unread note, struck through
// and dimmed when a completed todo), and the age since updated_at on the right.
// Clicking the glyph toggles status; clicking the rest of the row selects.
// When draggable, a press that moves 6 px becomes a drag and no longer
// selects on release.
Rectangle {
    id: root

    property var item: ({})
    property bool selected: false
    property bool draggable: false
    property bool lifted: false
    property color foreground: Color.foreground
    property int nowSeconds: 0

    signal picked()
    signal toggled()
    // Positions are in this row's coordinates.
    signal dragMoved(real x, real y)
    signal dropped()
    signal dragCanceled()

    readonly property bool readOrCompleted: ItemJs.isReadOrCompleted(root.item)
    readonly property bool todo: ItemJs.isTodo(root.item)

    height: Style.space(30)
    radius: Style.cornerRadius
    opacity: root.lifted ? Tone.lifted : 1
    color: root.selected
        ? Style.selectedFillFor(root.foreground, Color.accent)
        : (rowMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent")

    MouseArea {
        id: rowMouse
        anchors.fill: parent
        hoverEnabled: true
        // The list would otherwise take a vertical drag as a flick.
        preventStealing: true

        property point pressedAt
        property bool dragging: false

        onPressed: function(mouse) {
            rowMouse.pressedAt = Qt.point(mouse.x, mouse.y)
            rowMouse.dragging = false
        }
        onPositionChanged: function(mouse) {
            if (!rowMouse.pressed) return
            if (!rowMouse.dragging) {
                if (!root.draggable || Math.hypot(mouse.x - rowMouse.pressedAt.x, mouse.y - rowMouse.pressedAt.y) < 6) return
                rowMouse.dragging = true
            }
            root.dragMoved(mouse.x, mouse.y)
        }
        onReleased: if (rowMouse.dragging) root.dropped()
        onCanceled: {
            if (!rowMouse.dragging) return
            rowMouse.dragging = false
            root.dragCanceled()
        }
        onClicked: if (!rowMouse.dragging) root.picked()
    }

    Text {
        id: glyph
        x: Style.space(10)
        y: (root.height - height) / 2
        text: root.todo ? (root.readOrCompleted ? Icons.boxOn : Icons.boxOff) : Icons.note
        color: root.readOrCompleted ? Util.alpha(root.foreground, Tone.muted) : (root.todo ? root.foreground : Color.accent)
        font.family: Style.font.family
        font.pixelSize: Style.font.icon

        MouseArea {
            anchors.fill: parent
            anchors.margins: -Style.space(6)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggled()
        }
    }

    Rectangle {
        visible: !root.todo && !root.readOrCompleted
        width: Style.space(6)
        height: width
        radius: width / 2
        color: Color.urgent
        x: glyph.x + glyph.width - Style.space(3)
        y: glyph.y - Style.space(1)
    }

    Text {
        id: title
        anchors.left: glyph.right
        anchors.leftMargin: Style.space(9)
        anchors.right: meta.left
        anchors.rightMargin: Style.space(8)
        y: (root.height - height) / 2
        text: root.item.title || ""
        elide: Text.ElideRight
        color: root.readOrCompleted ? Util.alpha(root.foreground, Tone.muted)
            : root.selected ? Style.selectedStateColor(root.foreground, Color.accent) : root.foreground
        font.strikeout: root.todo && root.readOrCompleted
        font.bold: !root.readOrCompleted && !root.todo
        font.family: Style.font.family
        font.pixelSize: Style.font.body
    }

    Text {
        id: meta
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        y: (root.height - height) / 2
        text: ItemJs.relativeAge(Number(root.item.updated_at), root.nowSeconds)
        color: Util.alpha(root.foreground, Tone.secondary)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
    }
}
