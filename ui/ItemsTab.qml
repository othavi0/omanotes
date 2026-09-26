pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Item.js" as ItemJs
import "Tone.js" as Tone

FocusScope {
    id: root

    property QtObject db: null              // Panel's Data.ItemsDb instance
    property var toast: null                // ui/Toast instance (Panel-owned)
    property color foreground: Color.foreground

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

    // Focus hops title -> body through a tick with neither focused, so the
    // save waits one turn and re-checks. Nothing is scheduled for a blur that
    // leaves nothing to save, or it would land on a draft opened meanwhile.
    onEditorFocusedChanged: {
        if (root.editorFocused || !(root.draftNew || editorPane.dirty)) return
        Qt.callLater(function() { if (!root.editorFocused) root.commitIfDirty() })
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

    // A new model array can send a ListView back to the top, so the model is
    // set here, not bound. A new read of the same list (a reload, a move, a
    // status change) keeps the scroll; another filter or search starts from
    // the top.
    property string _shownList: ""
    onItemListChanged: {
        var shown = root.db ? root.db.listFilter + "\n" + root.db.listQuery : ""
        var y = shown === root._shownList ? listView.contentY - listView.originY : 0
        root._shownList = shown
        listView.model = root.itemList
        var bottom = Math.max(0, listView.contentHeight - listView.height)
        listView.contentY = listView.originY + Math.min(y, bottom)
    }

    // Order (CONTEXT.md): rows drag inside their block, never while the
    // search has text or the list still shows a search's results.
    readonly property bool canDrag: root.searchText === "" && !!root.db && root.db.listQuery === ""
    property int dragId: -1
    property int dropSlot: -1
    property point dragPoint
    readonly property var dragItem: root.dragId >= 0 ? root.itemList[ItemJs.indexOfId(root.itemList, root.dragId)] : null
    readonly property real rowStride: listView.count > 0 ? (listView.contentHeight + listView.spacing) / listView.count : 0

    // `y` is in listArea's coordinates. The slot counts the rows of the
    // dragged row's block from 0, and stays inside that block.
    function dragTo(item, x, y) {
        root.dragId = Number(item.id)
        root.dragPoint = Qt.point(x, y)
        var readOrCompleted = ItemJs.isReadOrCompleted(item)
        var start = -1
        var end = 0
        for (var i = 0; i < root.itemList.length; ++i) {
            if (ItemJs.isReadOrCompleted(root.itemList[i]) !== readOrCompleted) continue
            if (start < 0) start = i
            end = i + 1
        }
        var contentY = y - listView.y + listView.contentY - listView.originY
        var half = (root.rowStride - listView.spacing) / 2
        var slot = end - start
        for (var j = start; j < end; ++j) {
            if (contentY < j * root.rowStride + half) { slot = j - start; break }
        }
        root.dropSlot = slot
        dropLine.contentY = (start + slot) * root.rowStride - listView.spacing / 2
    }

    function endDrag() {
        root.dragId = -1
        root.dropSlot = -1
    }

    function drop() {
        var id = root.dragId
        var move = ItemJs.dropMove(root.itemList, id, root.dropSlot)
        root.endDrag()
        if (id < 0) return
        if (move && root.db) root.db.move(id, move.anchorId, move.after)
        root.selectItem(id)
    }

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

    // An open draft hides the selected row, so while a draft is open the
    // list hands focus to the draft's title.
    function focusList() {
        if (root.draftNew) editorPane.focusTitle()
        else focusSink.forceActiveFocus()
    }

    // Called by Panel.qml when the panel opens or this tab is re-shown.
    function resetFocus() {
        confirm.cancel()
        if (!editorPane.unsaved) root.refillEditor()
        root.focusList()
    }

    function selectItem(id) {
        root._selectAfterReload = -1
        root.selectedId = id
        root.commitIfDirty()
        root.focusList()
    }

    function pickItem(id) {
        root.selectItem(id)
        listView.positionViewAtIndex(root.selectedIndex, ListView.Center)
    }

    // Resolved from selectedId + itemList rather than the selectedItem
    // binding, which lags by one step inside onSelectedIdChanged.
    function refillEditor() {
        var idx = ItemJs.indexOfId(root.itemList, root.selectedId)
        editorPane.openItem(idx >= 0 ? root.itemList[idx] : null)
    }

    // A draft that cannot be committed stays open and takes the chosen type.
    function startNew(type) {
        if (!root.db) return
        root.commitIfDirty()
        root.draftType = type === "todo" ? "todo" : "note"
        if (root.draftNew) { Qt.callLater(function() { editorPane.focusTitle() }); return }
        confirm.cancel()
        root.draftNew = true
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

    // Every way out of the editor lands here. The Save button hands focus
    // back through focusList; a save caused by focus already having moved
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
            if (focusSink.activeFocus) root.focusList()
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

    // Holds focus for the tab when no field has it, so KeyboardPanel's
    // focusTarget lands inside the tab and Esc reaches Panel.qml.
    Item {
        id: focusSink
        anchors.fill: parent
        focus: true
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

    RowLayout {
        anchors.fill: parent
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
                id: listArea
                Layout.fillWidth: true
                Layout.fillHeight: true

                ListView {
                    id: listView
                    anchors.fill: parent
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    keyNavigationEnabled: false
                    spacing: Style.spacing.xxs
                    Component.onCompleted: listView.model = root.itemList

                    delegate: ItemRow {
                        id: row
                        required property var modelData
                        width: listView.width
                        item: modelData
                        selected: Number(modelData.id) === root.selectedId && !root.draftNew
                        draggable: root.canDrag
                        lifted: Number(modelData.id) === root.dragId
                        foreground: root.foreground
                        nowSeconds: root.nowSeconds
                        onPicked: root.pickItem(modelData.id)
                        onToggled: {
                            if (root.db) root.db.setStatus(modelData.id, ItemJs.isReadOrCompleted(modelData) ? 0 : 1)
                        }
                        onDragMoved: function(x, y) {
                            var p = row.mapToItem(listArea, x, y)
                            root.dragTo(row.modelData, p.x, p.y)
                        }
                        // The drop can reorder the model, which destroys this
                        // row, so it runs after the row's release handler.
                        onDropped: Qt.callLater(root.drop)
                        onDragCanceled: root.endDrag()
                    }
                }

                Rectangle {
                    id: dropLine
                    objectName: "dropLine"
                    property real contentY: 0
                    visible: root.dragId >= 0 && root.dropSlot >= 0
                    x: listView.x + Style.space(8)
                    y: listView.y + dropLine.contentY - listView.contentY + listView.originY - height / 2
                    width: listView.width - Style.space(16)
                    height: 2
                    color: Color.accent
                }

                Rectangle {
                    objectName: "dragFloat"
                    visible: !!root.dragItem
                    enabled: false
                    x: root.dragPoint.x - Style.space(20)
                    y: root.dragPoint.y - height / 2
                    width: listView.width
                    height: floatRow.height
                    radius: Style.cornerRadius
                    color: Color.popups.background
                    border.width: 1
                    border.color: Style.selectedBorderFor(root.foreground, Color.accent)

                    ItemRow {
                        id: floatRow
                        width: parent.width
                        item: root.dragItem || ({})
                        selected: !!root.dragItem
                        foreground: root.foreground
                        nowSeconds: root.nowSeconds
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
        // A reload rebuilds every row, so the row that held the drag is gone.
        function onItemsUpdated() {
            root.endDrag()
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
