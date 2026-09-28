import QtQuick
import qs.Commons
import "Icons.js" as Icons
import "Tone.js" as Tone

// What a list shows when it has no rows. By default it is the Items list:
// "Nothing here yet" with New note / New todo, or, when a search or filter
// hides every item, "No matches" with a button that clears both. History
// sets its own glyph, title and message and turns the create buttons off.
Column {
    id: root
    property bool filtered: false
    property bool creates: !root.filtered
    property string glyph: root.filtered ? "" : Icons.note
    property string title: root.filtered ? "No matches" : "Nothing here yet"
    property string message: root.filtered ? "" : "Keep a note or track a todo."
    // One bordered "+ <actionText>" button, for a list with its own way to
    // add a row, such as the Alarms tab.
    property string actionText: ""
    property color foreground: Color.foreground

    signal newNote()
    signal newTodo()
    signal clearSearch()
    signal actionClicked()

    spacing: Style.spacing.xxl

    Text {
        visible: root.glyph !== ""
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.glyph
        color: Util.alpha(root.foreground, Tone.muted)
        font.family: Style.font.family
        font.pixelSize: Style.space(34)
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.title
        color: root.foreground
        font.bold: true
        font.family: Style.font.family
        font.pixelSize: Style.font.title
    }

    Text {
        visible: root.message !== ""
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.message
        color: Util.alpha(root.foreground, Tone.secondary)
        font.family: Style.font.family
        font.pixelSize: Style.font.body
    }

    Loader {
        active: root.creates
        visible: active
        anchors.horizontalCenter: parent.horizontalCenter
        sourceComponent: Row {
            spacing: Style.spacing.lg

            ActionButton {
                bordered: true
                selected: true
                iconText: Icons.plus
                text: "New note"
                foreground: root.foreground
                onClicked: root.newNote()
            }
            ActionButton {
                bordered: true
                iconText: Icons.plus
                text: "New todo"
                foreground: root.foreground
                onClicked: root.newTodo()
            }
        }
    }

    Loader {
        active: root.filtered
        visible: active
        anchors.horizontalCenter: parent.horizontalCenter
        sourceComponent: ActionButton {
            bordered: true
            text: "Clear search and filter"
            foreground: root.foreground
            onClicked: root.clearSearch()
        }
    }

    Loader {
        active: root.actionText !== ""
        visible: active
        anchors.horizontalCenter: parent.horizontalCenter
        sourceComponent: ActionButton {
            bordered: true
            selected: true
            iconText: Icons.plus
            text: root.actionText
            foreground: root.foreground
            onClicked: root.actionClicked()
        }
    }
}
