pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Icons.js" as Icons
import "Item.js" as ItemJs
import "Tone.js" as Tone

// "History" tab: the log Db writes on every action (added, edited, completed,
// reopened, converted, deleted), rendered as a table of
// `type | title | action | timestamp` rows (newest-first, from db.history).
// Entries are never edited; the user can only delete one or clear them all.
// Title and row count live in PanelHeader's tab Segment, not here. The Toast
// is owned by Panel.qml and injected here.
FocusScope {
    id: root

    property QtObject db: null              // Panel's Data.Db instance
    property var toast: null                // ui/Toast instance (Panel-owned)
    property color foreground: Color.foreground

    signal closeRequested()                 // Esc in the list closes the panel

    property int selectedId: -1
    readonly property bool deleteArmed: confirm.isArmedFor(root.selectedId)
    readonly property bool clearArmed: confirm.isArmedFor("clear")
    readonly property bool clearButtonEnabled: root.db ? root.db.history.length > 0 : false

    onSelectedIdChanged: confirm.cancel()

    ArmedConfirm { id: confirm }

    readonly property var rowList: root.db ? (root.db.history || []) : []
    readonly property int selectedIndex: ItemJs.indexOfId(root.rowList, root.selectedId)
    readonly property var selectedRow: root.selectedIndex >= 0 ? root.rowList[root.selectedIndex] : null

    // Column widths shared by the header and every delegate so cells stay in
    // vertical alignment (title is the only elastic column).
    readonly property int colTypeW: Style.space(34)
    readonly property int colActionW: Style.space(76)
    readonly property int colTsW: Style.space(128)


    // Unix seconds -> "YYYY-MM-DD HH:MM".
    function formatTs(ts) {
        var n = Number(ts)
        if (!isFinite(n) || n <= 0) return "--"
        var d = new Date(n * 1000)
        function p(x) { return (x < 10 ? "0" : "") + x }
        return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate())
            + " " + p(d.getHours()) + ":" + p(d.getMinutes())
    }

    // Action scan-the-log colors: deletions in urgent, completions in accent.
    function actionColor(action) {
        var a = String(action || "")
        if (a === "deleted") return Color.urgent
        if (a === "completed") return Color.accent
        return Util.alpha(root.foreground, Tone.secondary)
    }

    function focusList() { pump.forceActiveFocus() }
    function resetFocus() {
        confirm.cancel()
        root.focusList()
    }

    function moveSelection(delta) {
        var rows = root.rowList
        var n = rows.length
        if (n === 0) return
        var cur = root.selectedIndex
        var next = Math.max(0, Math.min(n - 1, cur + delta))
        if (cur < 0 || next === cur) return
        root.selectedId = rows[next].id
        listView.positionViewAtIndex(next, ListView.Center)
    }

    function armDelete() {
        if (!root.db || !root.selectedRow) return
        if (confirm.press(root.selectedId)) root.db.deleteHistory(root.selectedId)
        else if (root.toast) root.toast.show("Delete again to confirm")
    }
    function clearHistory() {
        if (!root.db || root.rowList.length === 0) return
        if (confirm.press("clear")) root.db.clearHistory()
        else if (root.toast) root.toast.show("Clear again to confirm")
    }

    function onKey(event) {
        var mods = event.modifiers
        var text = mods & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier) ? ""
            : mods & Qt.ShiftModifier ? event.text : event.text.toLowerCase()
        if (event.key === Qt.Key_Down || text === "j") {
            root.moveSelection(1); event.accepted = true
        } else if (event.key === Qt.Key_Up || text === "k") {
            root.moveSelection(-1); event.accepted = true
        } else if (text === "d") {
            root.armDelete(); event.accepted = true
        } else if (text === "c") {
            root.clearHistory(); event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
            if (confirm.armed) confirm.cancel()
            else root.closeRequested()
            event.accepted = true
        }
    }

    // Keep a valid selection after refreshes (watcher/via db): when the
    // deleted/cleared row is gone, fall back to the newest row.
    function onHistoryChanged() {
        var rows = root.rowList
        if (rows.length === 0) {
            root.selectedId = -1
            confirm.cancel()
            return
        }
        if (ItemJs.indexOfId(rows, root.selectedId) < 0) {
            root.selectedId = rows[0].id
            if (root.selectedIndex >= 0) listView.positionViewAtIndex(root.selectedIndex, ListView.Center)
        }
    }

    Item {
        id: pump
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) { root.onKey(event) }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Style.spacing.sm

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Style.spacing.controlPaddingX
            Layout.rightMargin: Style.spacing.controlPaddingX
            spacing: Style.spacing.sm

            PanelSectionHeader { Layout.preferredWidth: root.colTypeW; text: "Type"; foreground: root.foreground }
            PanelSectionHeader { Layout.fillWidth: true; text: "Title"; foreground: root.foreground }
            PanelSectionHeader { Layout.preferredWidth: root.colActionW; text: "Action"; foreground: root.foreground }
            PanelSectionHeader { Layout.preferredWidth: root.colTsW; text: "Timestamp"; foreground: root.foreground }
        }

        PanelSeparator {
            Layout.fillWidth: true
            foreground: root.foreground
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            EmptyState {
                anchors.centerIn: parent
                visible: listView.count === 0
                creates: false
                glyph: Icons.history
                title: "No history yet"
                message: "Every change to an item is logged here."
                foreground: root.foreground
            }

            ListView {
                id: listView
                anchors.fill: parent
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                keyNavigationEnabled: false
                spacing: Style.spacing.xxs
                model: root.rowList

                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: listView.width
                    height: rowRow.implicitHeight + Style.space(10)
                    radius: Style.cornerRadius
                    color: Number(modelData.id) === root.selectedId
                        ? Style.selectedFillFor(root.foreground, Color.accent)
                        : rowMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

                    RowLayout {
                        id: rowRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Style.spacing.controlPaddingX
                        anchors.rightMargin: Style.spacing.controlPaddingX
                        spacing: Style.spacing.sm

                        Text {
                            Layout.preferredWidth: root.colTypeW
                            text: modelData.type !== "todo" ? Icons.note
                                : modelData.action === "completed" ? Icons.boxOn : Icons.boxOff
                            color: Number(modelData.id) === root.selectedId
                                ? Style.selectedStateColor(root.foreground, Color.accent)
                                : Util.alpha(root.foreground, Tone.secondary)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.icon
                        }

                        Text {
                            Layout.fillWidth: true
                            text: modelData.title
                            elide: Text.ElideRight
                            color: Number(modelData.id) === root.selectedId
                                ? Style.selectedStateColor(root.foreground, Color.accent)
                                : root.foreground
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                        }

                        Text {
                            Layout.preferredWidth: root.colActionW
                            text: ItemJs.historyLabel(modelData)
                            color: root.actionColor(modelData.action)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.bodySmall
                        }

                        Text {
                            Layout.preferredWidth: root.colTsW
                            text: root.formatTs(modelData.ts)
                            color: Util.alpha(root.foreground, Tone.secondary)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.bodySmall
                        }
                    }

                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton
                        onClicked: {
                            root.selectedId = modelData.id
                            confirm.cancel()
                            root.focusList()
                            listView.positionViewAtIndex(index, ListView.Center)
                        }
                    }
                }
            }
        }

        PanelSeparator {
            Layout.fillWidth: true
            foreground: root.foreground
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.md

            HintBar {
                Layout.fillWidth: true
                foreground: root.foreground
                urgent: root.deleteArmed || root.clearArmed
                hints: root.deleteArmed ? [["d", "press again to delete"]]
                    : root.clearArmed ? [["c", "press again to clear"]]
                    : [["j/k", "move"], ["d d", "delete"], ["c c", "clear"], ["1/2", "tabs"], ["Esc", "close"]]
            }

            ActionButton {
                text: root.clearArmed ? "Confirm" : "Clear history"
                bordered: true
                enabled: root.clearButtonEnabled
                foreground: root.clearButtonEnabled ? root.foreground : Util.alpha(root.foreground, Tone.muted)
                onClicked: { root.clearHistory(); root.focusList() }
            }
        }
    }

    Connections {
        target: root.db
        function onHistoryChanged() { root.onHistoryChanged() }
        function onHistoryRowDeleted(id) {
            var idx = ItemJs.indexOfId(root.rowList, Number(id))
            var title = idx >= 0 ? root.rowList[idx].title : "entry"
            if (root.toast) root.toast.show("Deleted — " + title)
            if (Number(id) === root.selectedId) root.selectedId = ItemJs.neighbourId(root.rowList, id)
        }
        function onHistoryCleared() {
            if (root.toast) root.toast.show("History cleared")
        }
    }

    Component.onCompleted: root.focusList()
}