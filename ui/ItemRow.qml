import QtQuick
import qs.Commons
import "Item.js" as ItemJs
import "Icons.js" as Icons
import "Tone.js" as Tone

// One row of the unified list: a checkbox (todo) or note glyph, an unread
// dot on unread notes, the title (bold when an unread note, struck through
// and dimmed when a completed todo), and the age since updated_at on the right.
// Clicking the glyph toggles status; clicking the rest of the row selects.
Rectangle {
    id: root

    property var item: ({})
    property bool selected: false
    property color foreground: Color.foreground
    property int nowSeconds: 0

    signal picked()
    signal toggled()

    readonly property bool readOrCompleted: ItemJs.isReadOrCompleted(root.item)
    readonly property bool todo: ItemJs.isTodo(root.item)

    height: Style.space(30)
    radius: Style.cornerRadius
    color: root.selected
        ? Style.selectedFillFor(root.foreground, Color.accent)
        : (rowMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent")

    MouseArea {
        id: rowMouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.picked()
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
