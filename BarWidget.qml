import QtQuick
import Quickshell.Io
import qs.Ui
import "data" as Data
import "ui/Icons.js" as Icons

BarWidget {
    id: root
    moduleName: "othavi0.omanotes"

    // Bar.qml's findPanelWidget requires open/close/opened on the bar-widget
    // root (not the nested panel), so the widget is the popout identity.
    readonly property bool opened: panelItem ? panelItem.opened === true : false

    function open() { if (panelItem) panelItem.open() }
    function close() { if (panelItem) panelItem.close() }
    function togglePanel() { if (panelItem) panelItem.toggle() }

    // Forwarded: Bar.requestPopout prefers closeForPopoutSwitch over close,
    // and KeyboardPanel reads popoutSwitchClosing back off its owner.
    readonly property bool popoutSwitchClosing: panelItem ? panelItem.popoutSwitchClosing === true : false
    function closeForPopoutSwitch() { if (panelItem) panelItem.closeForPopoutSwitch() }

    property var panelItem: null

    function injectPanel() {
        var target = panelLoader.item
        if (!target) return
        panelItem = target
        if ("bar" in target) target.bar = root.bar
        if ("settings" in target) target.settings = root.settings
        if ("anchorItem" in target) target.anchorItem = button
        if ("hostWidget" in target) target.hostWidget = root
        if ("db" in target) target.db = db
    }

    // Mutations go through the async sqlite3 Process, so `ok: true` means the
    // write is queued, and the FileView watcher's reload converges the change
    // onto the panels + allItems cache afterwards.
    function ipcReply(error) {
        return JSON.stringify(error ? { ok: false, error: error } : { ok: true })
    }
    function ipcAdd(type, title, body) {
        var t = String(title || "").trim()
        if (t === "") return ipcReply("title is required")
        return ipcReply(db.fromScript(function() { return db.add(type, t, String(body || "")) }))
    }
    function ipcList(type) {
        if (!db.allItemsLoaded) return ipcReply("not ready")
        var list = db.allItems
        var out = []
        for (var i = 0; i < list.length; ++i) {
            if (String(list[i].type) !== type) continue
            out.push({
                id: Number(list[i].id),
                type: String(list[i].type),
                title: String(list[i].title),
                body: String(list[i].body || ""),
                status: Number(list[i].status)
            })
        }
        return JSON.stringify(out)
    }
    // The Db reports a missing id only once the queued write has run, after
    // the reply is gone, so the id is looked up in the last reload instead.
    function ipcOnItem(id, write) {
        if (!db.allItemsLoaded) return ipcReply("not ready")
        var n = Number(id)
        var list = db.allItems
        for (var i = 0; i < list.length; ++i) {
            if (Number(list[i].id) === n) {
                var item = list[i]
                return ipcReply(db.fromScript(function() { return write(n, item) }))
            }
        }
        return ipcReply("item not found: " + n)
    }
    function ipcToggle(id) {
        return ipcOnItem(id, function(n, item) {
            return db.setStatus(n, Number(item.status) === 1 ? 0 : 1)
        })
    }
    function ipcRemove(id) {
        return ipcOnItem(id, function(n) { return db.deleteItem(n) })
    }
    function ipcClearHistory() {
        return ipcReply(db.fromScript(function() { return db.clearHistory() }))
    }

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    onBarChanged: injectPanel()
    onSettingsChanged: injectPanel()

    // The only Db of this widget: the IPC, the bar tooltip and the panel
    // (through injectPanel) all read and write through it.
    Data.Db {
        id: db
        Component.onCompleted: db.init()
    }

    readonly property int unreadNotes: db.unreadNotes
    readonly property int inProgressTodos: db.inProgressTodos

    Loader {
        id: panelLoader
        active: true
        source: Qt.resolvedUrl("Panel.qml")
        visible: false
        onLoaded: {
            root.injectPanel()
            Qt.callLater(root.injectPanel)
        }
    }

    IpcHandler {
        target: "scratchpad"

        function open(): void { root.open() }
        function close(): void { root.close() }
        function show(): void { root.open() }
        function hide(): void { root.close() }
        function toggle(): void { root.togglePanel() }

        // `delete` is a reserved word, so the per-row delete is exposed as
        // `remove`. Every method that returns a value answers JSON on stdout.
        function ping(): string { return root.ipcReply("") }
        function addNote(title: string, body: string): string {
            return root.ipcAdd("note", title, body)
        }
        function addTodo(title: string, body: string): string {
            return root.ipcAdd("todo", title, body)
        }
        function listNotes(): string { return root.ipcList("note") }
        function listTodos(): string { return root.ipcList("todo") }
        function toggleStatus(id: int): string { return root.ipcToggle(id) }
        function toggleTodo(id: int): string { return root.ipcToggle(id) }
        function remove(id: int): string { return root.ipcRemove(id) }
        function clearHistory(): string { return root.ipcClearHistory() }
    }

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: Icons.noteFilled
        tooltipText: "Omanotes (" + root.unreadNotes + " / " + root.inProgressTodos + ")"

        onPressed: function(b) {
            if (b === Qt.LeftButton) root.togglePanel()
        }
    }
}
