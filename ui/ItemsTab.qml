pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Item.js" as ItemJs
import "Tone.js" as Tone

// Keyboard map:
//   list:   j/k or ↑/↓ move · Enter/l/→/Tab edit the selected item
//           · n new draft · space/c toggle status · d delete (double-press
//           to confirm) · / focus search · f cycles All/Notes/Todos
//           · Esc closes the panel · 1/2 switch tabs (Panel.qml)
//           · every list key ignores Ctrl, Alt and Meta
//   editor: fields own printable keys · Enter/Tab title→body, body→save+list
//           · Esc saves (auto-save on leaving) · Shift+Esc discards
//           · Ctrl+T sets a draft's type to the other of note/todo
//   search: Enter/Tab/Shift+Tab return to the list, Esc clears and returns;
//           with a draft open they return to its title instead
FocusScope {
    id: root

    property QtObject db: null              // Panel's Data.Db instance
    property var toast: null                // ui/Toast instance (Panel-owned)
    property color foreground: Color.foreground

    signal closeRequested()                 // Esc in the list closes the panel

    property string filterType: "all"       // all | note | todo
    property int selectedId: -1
    property bool draftNew: false           // right pane holds a new-item draft
    property string draftType: "note"       // draft's type ('note' | 'todo')
    property int nowSeconds: Math.floor(Date.now() / 1000)

    readonly property bool deleteArmed: confirm.isArmedFor(root.selectedId)
    property alias searchText: searchField.text
    property alias editorTitle: editorPane.titleText
    property alias editorBody: editorPane.bodyText

    property int _selectAfterReload: -1
    property int _quietSaveId: -1
    property var _failedWrites: []

    readonly property bool draftNeedsTitle: root.draftNew && root.editorTitle.trim() === "" && root.editorBody.trim() !== ""
    readonly property bool editorFocused: editorPane.titleFocused || editorPane.bodyFocused
    readonly property string focusContext: {
        if (searchField.activeFocus) return "search"
        if (root.editorFocused) return root.draftNew ? "draft" : "editor"
        return "list"
    }

    // Focus hops title -> body through a tick with neither focused, so the
    // save waits one turn and re-checks. Nothing is scheduled for a blur that
    // leaves nothing to save, or it would land on a draft opened meanwhile.
    onEditorFocusedChanged: {
        if (root.editorFocused || !(root.draftNew || editorPane.dirty)) return
        Qt.callLater(function() { if (!root.editorFocused) root.commitIfDirty() })
    }

    readonly property var hintSets: ({
        list: [["j/k", "move"], ["Enter", "edit"], ["n", "new"], ["Space", "toggle"],
            ["d d", "delete"], ["/", "search"], ["f", "filter"], ["1/2", "tabs"], ["Esc", "close"]],
        search: [["Enter", "to list"], ["Esc", "clear"]],
        searchWithDraft: [["Enter", "to draft"], ["Esc", "clear"]],
        title: [["Enter/Tab", "to body"], ["Esc", "save and back"], ["Shift+Esc", "discard"]],
        body: [["Enter/Tab", "save and back"], ["Shift+Enter", "new line"], ["Shift+Tab", "to title"],
            ["Esc", "save and back"], ["Shift+Esc", "discard"]],
        untitledDraft: {
            title: [["Enter/Tab", "to body"], ["Shift+Esc", "discard"]],
            body: [["Shift+Enter", "new line"], ["Shift+Tab", "to title"], ["Shift+Esc", "discard"]]
        },
        draftType: [["Ctrl+T", "note/todo"]],
        deleteArmed: [["d", "press again to delete"]]
    })
    readonly property var hints: {
        if (root.deleteArmed) return root.hintSets.deleteArmed
        if (root.focusContext === "search") return root.draftNew ? root.hintSets.searchWithDraft : root.hintSets.search
        if (root.focusContext === "list") return root.hintSets.list
        var field = editorPane.bodyFocused ? "body" : "title"
        if (!root.draftNew) return root.hintSets[field]
        var fieldHints = root.draftNeedsTitle ? root.hintSets.untitledDraft[field] : root.hintSets[field]
        return fieldHints.concat(root.hintSets.draftType)
    }

    onSelectedIdChanged: {
        confirm.cancel()
        if (root.draftNew) return
        root.saveEdit()
        root.refillEditor()
    }

    readonly property var itemList: root.db ? (root.db.items || []) : []
    readonly property int selectedIndex: ItemJs.indexOfId(root.itemList, root.selectedId)
    readonly property var selectedItem: root.selectedIndex >= 0 ? root.itemList[root.selectedIndex] : null
    readonly property bool _filtered: root.filterType !== "all" || root.searchText.trim() !== ""

    function toggleStatus() {
        if (!root.db || !root.selectedItem) return
        root.db.setStatus(root.selectedItem.id, ItemJs.isReadOrCompleted(root.selectedItem) ? 0 : 1)
    }
    function convertSelected() {
        if (!root.db || !root.selectedItem) return
        root.db.convertType(root.selectedItem.id)
    }
    function copySelected() {
        if (!root.selectedItem) return
        var title = String(root.selectedItem.title || "")
        var body = String(root.selectedItem.body || "")
        Quickshell.clipboardText = body === "" ? title : (title + "\n\n" + body)
        if (root.toast) root.toast.show("Copied")
    }
    function armDelete() {
        if (!root.db || !root.selectedItem) return
        if (confirm.press(root.selectedId)) root.db.deleteItem(root.selectedId)
        else if (root.toast) root.toast.show("Delete again to confirm")
    }

    function focusSearch() { searchField.forceActiveFocus() }
    // An open draft hides the selected row, and list keys act on that row,
    // so while a draft is open the list hands focus to the draft's title.
    function focusList() {
        if (root.draftNew) editorPane.focusTitle()
        else pump.forceActiveFocus()
    }

    // Called by Panel.qml when the panel opens or this tab is re-shown.
    function resetFocus() {
        confirm.cancel()
        if (!editorPane.unsaved) root.refillEditor()
        root.focusList()
    }

    function pickItem(id) {
        root._selectAfterReload = -1
        root.selectedId = id
        root.commitIfDirty()
        root.focusList()
        listView.positionViewAtIndex(root.selectedIndex, ListView.Center)
    }
    function moveSelection(delta) {
        var items = root.itemList
        var n = items.length
        if (n === 0) return
        var cur = root.selectedIndex
        var next = Math.max(0, Math.min(n - 1, cur + delta))
        root.selectedId = items[next].id
        listView.positionViewAtIndex(next, ListView.Center)
    }

    // Resolved from selectedId + itemList rather than the selectedItem
    // binding, which lags by one step inside onSelectedIdChanged.
    function refillEditor() {
        var idx = ItemJs.indexOfId(root.itemList, root.selectedId)
        editorPane.openItem(idx >= 0 ? root.itemList[idx] : null)
    }

    function focusEditor() {
        confirm.cancel()
        if (root.draftNew) { Qt.callLater(function() { editorPane.focusTitle() }); return }
        if (!root.selectedItem) { root.startNew("note"); return }
        root.draftNew = false
        root.refillEditor()
        Qt.callLater(function() { editorPane.focusTitle() })
    }

    function startNew(type) {
        if (!root.db) return
        root.commitIfDirty()
        if (root.draftNew) { Qt.callLater(function() { editorPane.focusTitle() }); return }
        confirm.cancel()
        root.draftNew = true
        root.draftType = type === "todo" ? "todo" : "note"
        editorPane.openDraft()
        Qt.callLater(function() { editorPane.focusTitle() })
    }

    function saveEdit() {
        var e = editorPane.takeEdit()
        if (!e) return
        root.db.update(e.id, e.title, e.body)
        if (!e.titleWasEmpty) return
        root._quietSaveId = e.id
        if (root.toast) root.toast.show("Title can't be empty — kept “" + e.title + "”")
    }

    // Every way out of the editor lands here. Keys and the Save button hand
    // focus back through focusList; a save caused by focus already having moved
    // (a click into the search field, the panel closing) leaves focus alone.
    function commitEditor(returnFocus) {
        if (root.draftNeedsTitle) {
            if (root.toast) root.toast.show("New item needs a title")
        } else if (root.draftNew) {
            var title = String(editorPane.titleText || "").trim()
            var body = String(editorPane.bodyText || "")
            root.draftNew = false
            root.refillEditor()
            if (title !== "") root.db.add(root.draftType, title, body)
        } else {
            root.saveEdit()
        }
        if (returnFocus) root.focusList()
    }

    function discardEditor() {
        root.draftNew = false
        root.refillEditor()
        root.focusList()
    }

    // Failed writes come back one at a time: each waits until the editor holds
    // no other unsaved text, and an edit also waits for its item to be listed.
    function restoreFailed() {
        while (root._failedWrites.length > 0 && !editorPane.unsaved) {
            var w = root._failedWrites[0]
            var idx = ItemJs.indexOfId(root.itemList, w.args.id)
            if (w.kind === "update" && idx < 0 && !root.isRemoved(w.args.id)) { root.showAll(); return }
            root._failedWrites.shift()
            if (w.kind === "add") {
                confirm.cancel()
                root.draftNew = true
                root.draftType = w.args.type
                editorPane.reopen(null, w.args.title, w.args.body)
            } else if (idx >= 0) {
                root.selectedId = w.args.id
                editorPane.reopen(root.itemList[idx], w.args.title, w.args.body)
            } else if (root.toast) {
                root.toast.show("Item removed elsewhere")
            }
            if (pump.activeFocus) root.focusList()
        }
    }

    function isRemoved(id) {
        var filtered = root.db.listFilter !== "all" || root.db.listQuery.trim() !== ""
        return ItemJs.isRemoved(id, root.itemList, filtered, root.db.allItemsLoaded ? root.db.allItems : null)
    }

    function showAll() {
        searchField.text = ""
        root.filterType = "all"
        filterDebounce.restart()
    }

    function commitIfDirty() {
        if (root.draftNew || editorPane.dirty) root.commitEditor(false)
    }

    function cycleFilter() {
        var order = ["all", "note", "todo"]
        root.filterType = order[(order.indexOf(root.filterType) + 1) % order.length]
        filterDebounce.restart()
    }

    function onListKey(event) {
        // Shift is left alone: it already turns "j" into "J", and some
        // layouts need it to type "/". Caps Lock sends "J" with no
        // modifier at all, so that text is lowered.
        var mods = event.modifiers
        if (mods & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
        var text = mods & Qt.ShiftModifier ? event.text : event.text.toLowerCase()
        if (event.key === Qt.Key_Down || text === "j") {
            root.moveSelection(1); event.accepted = true
        } else if (event.key === Qt.Key_Up || text === "k") {
            root.moveSelection(-1); event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
            || event.key === Qt.Key_Right || event.key === Qt.Key_Tab || text === "l") {
            root.focusEditor(); event.accepted = true
        } else if (event.key === Qt.Key_Space || text === "c") {
            root.toggleStatus(); event.accepted = true
        } else if (text === "d") {
            root.armDelete(); event.accepted = true
        } else if (text === "n" || text === "a") {
            root.startNew("note"); event.accepted = true
        } else if (text === "/") {
            root.focusSearch(); event.accepted = true
        } else if (text === "f") {
            root.cycleFilter(); event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
            if (confirm.armed) confirm.cancel()
            else root.closeRequested()
            event.accepted = true
        }
    }

    Item {
        id: pump
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) { root.onListKey(event) }
    }

    Timer {
        id: filterDebounce
        interval: 120
        onTriggered: {
            root._selectAfterReload = -1
            if (root.db) root.db.list(root.filterType, root.searchText)
        }
    }

    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: root.nowSeconds = Math.floor(Date.now() / 1000)
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Style.spacing.xxl

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Style.spacing.xxl

            ColumnLayout {
                Layout.preferredWidth: Style.space(270)
                Layout.minimumWidth: Style.space(270)
                Layout.maximumWidth: Style.space(270)
                Layout.fillHeight: true
                spacing: Style.spacing.lg

                SearchField {
                    id: searchField
                    Layout.fillWidth: true
                    foreground: root.foreground
                    activeFocusOnTab: false
                    onTextChanged: filterDebounce.restart()
                    onAccepted: root.focusList()
                    Keys.onPressed: function(event) {
                        if (event.key === Qt.Key_Escape) {
                            searchField.text = ""; root.focusList(); event.accepted = true
                        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                            root.focusList(); event.accepted = true
                        }
                    }
                }

                Segment {
                    id: typeSegment
                    Layout.fillWidth: true
                    value: root.filterType
                    foreground: root.foreground
                    options: [
                        { value: "all", label: "All", count: root.db ? (root.db.totalNotes + root.db.totalTodos) : 0 },
                        { value: "note", label: "Notes", count: root.db ? root.db.totalNotes : 0 },
                        { value: "todo", label: "Todos", count: root.db ? root.db.totalTodos : 0 }
                    ]
                    onPicked: function(v) { root.filterType = v; filterDebounce.restart() }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    ListView {
                        id: listView
                        anchors.fill: parent
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        keyNavigationEnabled: false
                        spacing: Style.spacing.xxs
                        model: root.itemList

                        delegate: ItemRow {
                            required property var modelData
                            width: listView.width
                            item: modelData
                            selected: Number(modelData.id) === root.selectedId && !root.draftNew
                            foreground: root.foreground
                            nowSeconds: root.nowSeconds
                            onPicked: root.pickItem(modelData.id)
                            onToggled: {
                                if (root.db) root.db.setStatus(modelData.id, ItemJs.isReadOrCompleted(modelData) ? 0 : 1)
                            }
                        }
                    }

                    EmptyState {
                        anchors.centerIn: parent
                        visible: listView.count === 0
                        filtered: root._filtered
                        foreground: root.foreground
                        onNewNote: root.startNew("note")
                        onNewTodo: root.startNew("todo")
                        onClearSearch: {
                            root.showAll()
                            root.focusList()
                        }
                    }
                }
            }

            PanelSeparator {
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                foreground: root.foreground
            }

            EditorPane {
                id: editorPane
                visible: !!root.selectedItem || root.draftNew
                Layout.fillWidth: true
                Layout.fillHeight: true
                item: root.selectedItem
                draft: root.draftNew
                draftType: root.draftType
                deleteArmed: root.deleteArmed
                nowSeconds: root.nowSeconds
                foreground: root.foreground
                onLeaveRequested: root.commitEditor(true)
                onConvertDraftRequested: function(type) { root.draftType = type }
                onToggleRequested: root.toggleStatus()
                onConvertRequested: root.convertSelected()
                onCopyRequested: root.copySelected()
                onDeleteClicked: root.armDelete()
                onSaveRequested: root.commitEditor(true)
                onDiscardRequested: root.discardEditor()
                onUnsavedChanged: if (!editorPane.unsaved) Qt.callLater(root.restoreFailed)
            }

            Item {
                visible: !root.selectedItem && !root.draftNew
                Layout.fillWidth: true
                Layout.fillHeight: true

                Text {
                    anchors.centerIn: parent
                    text: "Your note or todo opens here."
                    color: Util.alpha(root.foreground, Tone.muted)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                }
            }
        }

        PanelSeparator {
            Layout.fillWidth: true
            foreground: root.foreground
        }

        HintBar {
            Layout.fillWidth: true
            hints: root.hints
            urgent: root.deleteArmed
            foreground: root.foreground
        }
    }

    ArmedConfirm { id: confirm }

    function onItemsSynced() {
        if (root.draftNew) return
        var items = root.itemList
        if (editorPane.editingId >= 0 && (editorPane.dirty || root.editorFocused)
                && root.isRemoved(editorPane.editingId)) {
            editorPane.openItem(null)
            if (root.toast) root.toast.show("Item removed elsewhere")
            root.focusList()
        }
        if (root._selectAfterReload >= 0 && ItemJs.indexOfId(items, root._selectAfterReload) >= 0) {
            root.selectedId = root._selectAfterReload
            root._selectAfterReload = -1
            listView.positionViewAtIndex(root.selectedIndex, ListView.Center)
        }
        var refill = !root.editorFocused && !editorPane.dirty
        if (ItemJs.indexOfId(items, root.selectedId) >= 0) {
            if (refill) root.refillEditor()
            return
        }
        root.selectedId = items.length > 0 ? items[0].id : -1
        if (refill) root.refillEditor()
        if (items.length > 0) listView.positionViewAtIndex(0, ListView.Center)
    }

    Connections {
        target: root.db
        function onItemsUpdated() {
            root.onItemsSynced()
            root.restoreFailed()
        }
        function onAdded(id, type, title) {
            root._selectAfterReload = Number(id)
            if (root.toast) root.toast.show("Added " + type + " — " + title)
        }
        function onUpdated(id, title) {
            if (id === root._quietSaveId) { root._quietSaveId = -1; return }
            if (root.toast) root.toast.show("Saved — " + title)
        }
        function onStatusChanged(id, status) {
            if (Number(id) !== root.selectedId || !root.toast) return
            var item = root.selectedItem
            if (!item) return
            root.toast.show(ItemJs.statusToast(item, status))
        }
        function onTypeChanged(id) {
            var idx = ItemJs.indexOfId(root.itemList, Number(id))
            if (idx < 0 || !root.toast) return
            var before = root.itemList[idx]
            var newType = ItemJs.isTodo(before) ? "note" : "todo"
            root.toast.show("Converted to " + newType + " — " + before.title)
        }
        function onItemDeleted(id) {
            if (Number(id) === editorPane.editingId) editorPane.openItem(null)
            if (Number(id) !== root.selectedId) return
            if (root.toast) root.toast.show("Deleted")
            root.selectedId = ItemJs.neighbourId(root.itemList, id)
        }
        // The one error toast for the panel: HistoryTab shares this Db.
        function onFailed(message) {
            if (root.toast) root.toast.show("Error: " + String(message || "unknown"), true)
        }
        function onWriteFailed(kind, args, message) {
            if (kind !== "add" && kind !== "update") return
            if (kind === "update" && args.id === root._quietSaveId) root._quietSaveId = -1
            if (message === "item not found") return
            root._failedWrites.push({ kind: kind, args: args })
            root.restoreFailed()
        }
    }

    Component.onCompleted: {
        root.refillEditor()
        root.focusList()
    }
}
