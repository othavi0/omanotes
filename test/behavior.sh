#!/usr/bin/env bash
# Drives the real Panel.qml against a seeded sqlite db, offscreen, then asserts
# on the rows that reached the db. Covers the editor's save-on-leave contract
# and the on-screen controls that replace the old shortcuts: clicks on the real
# buttons and rows, and key presses that must do nothing.

set -euo pipefail
source "$(dirname "$0")/lib/harness.sh"

# The kit's KeyboardPanel is a layer-shell window with no offscreen backend,
# so it is the one kit file swapped for a plain window. Everything else,
# Panel.qml's open/close and tab wiring included, runs as shipped.
ln -s "$worktree/Panel.qml" "$cfg_dir/Panel.qml"
rm "$cfg_dir/Ui"
mkdir "$cfg_dir/Ui"
for f in "$shell_root"/Ui/*; do
  [[ "${f##*/}" == KeyboardPanel.qml ]] || ln -s "$f" "$cfg_dir/Ui/"
done
cat > "$cfg_dir/Ui/KeyboardPanel.qml" <<'QML'
import QtQuick
import Quickshell

FloatingWindow {
  property Item anchorItem
  property QtObject bar
  property var owner
  property bool open
  property int contentWidth
  property int contentHeight
  property Item focusTarget: null
  function fittedContentWidth(width) { return width }
  function fittedContentHeight(height) { return height }
  implicitWidth: contentWidth
  implicitHeight: contentHeight
  visible: open
  // The map hands keyboard focus to focusTarget alone, as the kit documents.
  // Window focus set before the map is taken away first, so a panel that
  // relies on it and not on focusTarget loses the first keys.
  Item { id: beforeMap }
  onOpenChanged: if (open) Qt.callLater(function() {
    if (!open) return
    beforeMap.forceActiveFocus()
    if (focusTarget) focusTarget.forceActiveFocus()
  })
}
QML

cat > "$cfg_dir/shell.qml" <<'QML'
import QtQuick
import QtTest
import Quickshell
import "data" as Data
import "ui/Icons.js" as Icons

ShellRoot {
  id: sr
  property int stepIndex: 0
  property bool started: false
  property int writeFailures: 0
  property int lastId: -1
  property int keepId: -1
  property int beforeLastId: -1
  property int probeId: -1
  property int armedId: -1
  property var before: null
  property var panel: null
  property var itemsTab: null
  property var historyTab: null
  property var header: null
  property var toast: null
  readonly property var db: sr.itemsTab ? sr.itemsTab.db : null

  function titleOf(id) {
    for (var i = 0; i < db.items.length; ++i) if (Number(db.items[i].id) === id) return db.items[i].title
    return "missing"
  }
  readonly property var steps: [
    function() { itemsTab.pickItem(2); sr.clickTitle() },
    function() { itemsTab.editorTitle = "EDITED-RENEW"; itemsTab.pickItem(3) },
    function() { itemsTab.commitIfDirty() },
    function() { console.log("HIGHLIGHTED " + sr.highlighted(itemsTab).join(",")) },

    function() { itemsTab.pickItem(4); sr.clickTitle() },
    function() { itemsTab.editorTitle = "EDITED-COFFEE"; sr.clickSearch() },
    function() { console.log("FOCUS-AFTER-SEARCH " + sr.focusContext() + " TITLE4 " + sr.titleOf(4)) },
    function() { itemsTab.searchText = "panel" },
    function() { itemsTab.searchText = "" },

    function() { itemsTab.startNew("note") },
    function() { itemsTab.editorTitle = "DRAFT-ON-CLOSE"; panel.close() },
    function() { panel.open() },

    function() { itemsTab.pickItem(5); sr.clickTitle() },
    function() { itemsTab.startNew("todo") },
    function() { itemsTab.editorTitle = "DRAFT-BY-SAVE"; sr.click(sr.button(sr.editor(), "Save todo")) },

    function() { itemsTab.pickItem(1); sr.clickTitle() },
    function() { itemsTab.editorTitle = "DISCARDED"; itemsTab.discardEditor() },
    function() { itemsTab.commitIfDirty() },

    function() { itemsTab.pickItem(5); itemsTab.convertSelected() },

    function() { itemsTab.pickItem(3); sr.clickTitle() },
    function() { itemsTab.editorTitle = ""; itemsTab.editorBody = "BODY-KEPT"; itemsTab.pickItem(1) },

    function() { sr.lastId = db.items[db.items.length - 1].id; sr.beforeLastId = db.items[db.items.length - 2].id; itemsTab.pickItem(sr.lastId) },
    function() { itemsTab.armDelete(); itemsTab.armDelete() },
    function() { console.log("AFTER-DELETE-LAST " + (itemsTab.selectedId === sr.beforeLastId ? "previous-row" : "other:" + itemsTab.selectedId)) },

    function() { itemsTab.searchText = "zzz_no_match" },
    function() { itemsTab.startNew("note") },
    function() { itemsTab.editorTitle = "DRAFT-IN-EMPTY-LIST"; db.load() },
    function() { console.log("DRAFT-AFTER-RELOAD " + itemsTab.draftNew + " " + itemsTab.editorTitle) },
    function() { itemsTab.commitEditor(true) },
    function() { itemsTab.searchText = "" },

    function() { itemsTab.pickItem(1); sr.clickTitle() },
    function() { itemsTab.editorBody = "QUEUED-BODY"; itemsTab.pickItem(2); itemsTab.convertSelected(); itemsTab.toggleStatus() },

    function() { itemsTab.filterType = "todo"; itemsTab.searchText = "upstream" },
    function() { sr.keepId = itemsTab.selectedId; itemsTab.startNew("note") },
    function() { itemsTab.editorTitle = "NOTE-HIDDEN-BY-FILTER"; itemsTab.commitEditor(true) },
    function() { itemsTab.filterType = "all"; itemsTab.searchText = "" },
    function() { console.log("SELECTION-AFTER-WIDENING " + (itemsTab.selectedId === sr.keepId ? "kept" : "hijacked:" + itemsTab.selectedId)) },

    function() { itemsTab.pickItem(4); sr.clickTitle() },
    function() { itemsTab.editorBody = "THROWN-AWAY"; itemsTab.discardEditor(); itemsTab.startNew("note") },
    function() { console.log("DRAFT-AFTER-DISCARD " + itemsTab.draftNew); itemsTab.discardEditor() },

    function() {
      console.log("HINT-BARS " + (sr.findType(itemsTab, "HintBar") === null) + " " + (sr.findType(historyTab, "HintBar") === null))
      var editor = sr.editor()
      var bottom = editor.mapToItem(itemsTab, 0, editor.height).y
      console.log("EDITOR-REACHES-BOTTOM " + (Math.abs(itemsTab.height - bottom) <= 1))
      sr.click(sr.firstRow()); sr.click(sr.newButton())
    },
    function() {
      console.log("NEW-MENU " + sr.menuShown() + " " + !!sr.menuButton("Note") + " " + !!sr.menuButton("Todo")
        + " draft=" + itemsTab.draftNew + " tooltip=[" + sr.newButton().tooltipText + "]")
      sr.click(sr.menuButton("Todo"))
    },
    function() {
      console.log("NEW-TODO-DRAFT " + itemsTab.draftNew + " " + itemsTab.draftType + " " + sr.focusContext() + " menu=" + sr.menuShown())
      sr.type("menu todo"); sr.click(sr.newButton())
    },
    function() { sr.click(sr.menuButton("Note")) },
    function() {
      console.log("NEW-NOTE-DRAFT " + itemsTab.draftNew + " " + itemsTab.draftType + " [" + itemsTab.editorTitle + "] "
        + sr.focusContext() + " menu=" + sr.menuShown())
      sr.click(sr.newButton())
    },
    function() { sr.click(sr.findByText(header, "History")) },
    function() {
      console.log("MENU-AFTER-OUTSIDE-CLICK " + sr.menuShown() + " " + panel.activeTab)
      sr.click(sr.findByText(header, "Items"))
    },

    function() { sr.click(sr.newButton()) },
    function() { sr.click(sr.menuButton("Note")) },
    function() { keys.keyClick(Qt.Key_Tab, Qt.NoModifier, -1); sr.type("orphan body") },
    function() { keys.keyClick(Qt.Key_Return, Qt.NoModifier, -1) },
    function() {
      console.log("ENTER-IN-DRAFT-BODY " + (itemsTab.editorBody === "orphan body\n") + " " + sr.focusContext())
      keys.keyClick(Qt.Key_Backspace, Qt.NoModifier, -1)
      toast.text = ""; keys.keyClick(Qt.Key_Escape, Qt.NoModifier, -1)
    },
    function() { console.log("UNTITLED-DRAFT-AFTER-ESC " + panel.opened + " " + sr.draftState()); panel.open() },
    function() { console.log("UNTITLED-DRAFT-AFTER-REOPEN " + sr.draftState()); sr.click(sr.firstRow()) },
    function() { console.log("UNTITLED-DRAFT-AFTER-ROW-CLICK " + sr.draftState()); sr.click(sr.findByText(header, "History")) },
    function() { sr.click(sr.findByText(header, "Items")) },
    function() { console.log("UNTITLED-DRAFT-AFTER-TAB-SWITCH " + sr.draftState()); sr.click(sr.newButton()) },
    function() { sr.click(sr.menuButton("Todo")) },
    function() {
      console.log("UNTITLED-DRAFT-AFTER-NEW " + sr.draftState() + " " + itemsTab.draftType)
      sr.click(sr.button(sr.editor(), "Discard"))
    },
    function() {
      console.log("UNTITLED-DRAFT-AFTER-DISCARD " + itemsTab.draftNew + " " + sr.focusContext())
      sr.click(sr.newButton())
    },
    function() { sr.click(sr.menuButton("Note")) },
    function() { toast.text = ""; keys.keyClick(Qt.Key_Escape, Qt.NoModifier, -1) },
    function() {
      console.log("EMPTY-DRAFT-AFTER-ESC " + panel.opened + " " + itemsTab.draftNew + " toast=[" + toast.text + "]")
      panel.open()
    },

    function() { itemsTab.pickItem(1); sr.clickTitle() },
    function() { keys.keyClick(Qt.Key_Tab, Qt.NoModifier, -1) },
    function() { console.log("TAB-IN-TITLE " + sr.editor().bodyFocused); keys.keyClick(Qt.Key_Backtab, Qt.ShiftModifier, -1) },
    function() { console.log("SHIFT-TAB-IN-BODY " + sr.editor().titleFocused); keys.keyClick(Qt.Key_Return, Qt.NoModifier, -1) },
    function() {
      console.log("ENTER-IN-TITLE " + sr.editor().bodyFocused)
      sr.probeId = itemsTab.selectedId; sr.before = itemsTab.editorBody
      keys.keyClick(Qt.Key_Return, Qt.NoModifier, -1)
    },
    function() {
      var added = itemsTab.editorBody.split("\n").length - sr.before.split("\n").length
      console.log("ENTER-IN-BODY " + (added === 1) + " " + sr.editor().bodyFocused + " " + sr.editor().dirty)
      keys.keyClick(Qt.Key_Escape, Qt.ShiftModifier, -1)
    },
    function() {
      console.log("SHIFT-ESC-IN-EDITOR " + panel.opened + " " + sr.editor().dirty + " " + (itemsTab.selectedId === sr.probeId))
      sr.click(sr.button(sr.editor(), "Discard"))
    },
    function() { sr.click(sr.newButton()) },
    function() { sr.click(sr.menuButton("Note")) },
    function() { sr.type("tomar"); sr.ctrl([Qt.Key_T]) },
    function() {
      console.log("CTRL-T-IN-DRAFT-TITLE [" + itemsTab.editorTitle + "] " + itemsTab.draftType)
      keys.keyClick(Qt.Key_Tab, Qt.NoModifier, -1)
    },
    function() { sr.ctrl([Qt.Key_T]) },
    function() {
      console.log("CTRL-T-IN-DRAFT-BODY [" + itemsTab.editorBody + "] " + itemsTab.draftType)
      keys.keyClick(Qt.Key_Escape, Qt.ShiftModifier, -1)
    },
    function() {
      console.log("SHIFT-ESC-IN-DRAFT " + panel.opened + " " + itemsTab.draftNew + " [" + itemsTab.editorTitle + "]")
      sr.clickTitle()
    },
    function() { sr.type("2") },
    function() {
      console.log("TWO-IN-TITLE " + panel.activeTab + " [" + itemsTab.editorTitle + "]")
      sr.click(sr.button(sr.editor(), "Discard"))
    },
    function() { sr.clickSearch(); sr.type("1") },
    function() { console.log("ONE-IN-SEARCH " + panel.activeTab + " [" + itemsTab.searchText + "] " + sr.focusContext()); itemsTab.searchText = "" },

    // Letters go through keyClickChar, since keyClick sends a key code with
    // no text.
    function() { if (!panel.opened) panel.open() },
    function() {
      sr.click(sr.firstRow())
      sr.before = sr.listState()
      sr.type("jklnacdd/f12J")
      var codes = [Qt.Key_Down, Qt.Key_Up, Qt.Key_Right, Qt.Key_Space, Qt.Key_Return, Qt.Key_Enter, Qt.Key_Tab]
      for (var i = 0; i < codes.length; ++i) keys.keyClick(codes[i], Qt.NoModifier, -1)
    },
    function() { console.log("LIST-KEYS " + sr.sameState(sr.before, sr.listState())); if (!panel.opened) panel.open() },
    function() { sr.click(sr.findByText(header, "History")) },
    function() {
      sr.click(sr.historyRow(historyTab.rowList[1].id))
      sr.before = sr.historyState()
      sr.type("jkddcc12")
      keys.keyClick(Qt.Key_Down, Qt.NoModifier, -1); keys.keyClick(Qt.Key_Up, Qt.NoModifier, -1)
    },
    function() { console.log("HISTORY-KEYS " + sr.sameState(sr.before, sr.historyState())) },
    function() {
      var mods = [Qt.ControlModifier, Qt.AltModifier, Qt.MetaModifier, Qt.ShiftModifier]
      for (var i = 0; i < mods.length; ++i) keys.keyClick(Qt.Key_Escape, mods[i], -1)
      console.log("ESC-WITH-MODIFIER-IN-HISTORY " + panel.opened)
      keys.keyClick(Qt.Key_Escape, Qt.NoModifier, -1)
    },
    function() {
      console.log("ESC-IN-HISTORY " + panel.opened)
      panel.open()
    },
    function() {
      sr.click(sr.firstRow())
      var mods = [Qt.ControlModifier, Qt.AltModifier, Qt.MetaModifier, Qt.ShiftModifier]
      for (var i = 0; i < mods.length; ++i) keys.keyClick(Qt.Key_Escape, mods[i], -1)
      console.log("ESC-WITH-MODIFIER-IN-LIST " + panel.opened)
      keys.keyClick(Qt.Key_Escape, Qt.NoModifier, -1)
    },
    function() { console.log("ESC-IN-LIST " + panel.opened); panel.open() },
    function() { sr.clickSearch(); sr.type("cof") },
    function() {
      keys.keyClick(Qt.Key_Escape, Qt.NoModifier, -1)
      console.log("ESC-IN-SEARCH " + panel.opened)
      panel.open(); itemsTab.searchText = ""
    },
    function() { itemsTab.pickItem(2); sr.clickTitle() },
    function() {
      itemsTab.editorTitle = "ESC-COMMITS"
      keys.keyClick(Qt.Key_Escape, Qt.NoModifier, -1)
      console.log("ESC-IN-EDITOR " + panel.opened)
    },
    function() { panel.open() },

    function() { sr.click(sr.findByText(itemsTab, "Todos")) },
    function() {
      console.log("FILTER-AFTER-TODOS-CLICK " + itemsTab.filterType + " notes=" + db.items.filter(function(i) { return i.type !== "todo" }).length)
      sr.click(sr.findByText(itemsTab, "All"))
    },

    // The item is a note, so its toggles below log read and unread.
    function() {
      sr.keepId = itemsTab.itemList.filter(function(i) { return i.type === "note" })[0].id; itemsTab.pickItem(sr.keepId)
      sr.click(sr.button(sr.editor(), "Delete"))
      var armedFirst = itemsTab.deleteArmed
      itemsTab.pickItem(itemsTab.itemList.filter(function(i) { return i.id !== sr.keepId })[0].id)
      var armedAfterMove = itemsTab.deleteArmed
      itemsTab.pickItem(sr.keepId)
      sr.click(sr.button(sr.editor(), "Delete"))
      console.log("ITEMS-ARMED-AFTER-MOVE " + armedFirst + " " + armedAfterMove + " " + itemsTab.deleteArmed)
      db.setStatus(sr.keepId, 1); db.setStatus(sr.keepId, 0)
    },
    function() {
      console.log("ITEMS-DELETE-AFTER-MOVING-BACK " + (sr.titleOf(sr.keepId) === "missing" ? "deleted" : "kept"))
      sr.click(sr.findByText(header, "History"))
    },
    function() {
      var rows = historyTab.rowList
      sr.armedId = rows[0].id
      sr.hover(sr.historyRow(sr.armedId))
      console.log("TRASH-ON-HOVER " + sr.trashOf(sr.armedId).visible + " " + sr.trashOf(rows[1].id).visible)
      sr.click(sr.trashOf(sr.armedId))
    },
    function() {
      var trash = sr.trashOf(sr.armedId)
      console.log("TRASH-ARMED " + trash.visible + " [" + trash.text + "] rows=" + historyTab.rowList.length)
      sr.click(sr.historyRow(historyTab.rowList[1].id))
    },
    function() {
      var trash = sr.trashOf(sr.armedId)
      console.log("TRASH-AFTER-SELECT [" + trash.text + "] " + historyTab.rowList.length)
      var row = sr.historyRow(sr.armedId)
      sr.hover(row); sr.click(sr.trashOf(sr.armedId))
      console.log("TRASH-REARMED [" + sr.trashOf(sr.armedId).text + "]")
      sr.click(sr.findByText(header, "Items")); sr.click(sr.findByText(header, "History"))
    },
    function() {
      console.log("TRASH-AFTER-TAB-SWITCH [" + sr.trashOf(sr.armedId).text + "] " + historyTab.rowList.length)
      var rows = historyTab.rowList
      sr.armedId = rows[1].id; sr.probeId = rows[2].id
      sr.click(sr.historyRow(sr.armedId))
      sr.hover(sr.historyRow(sr.armedId)); sr.click(sr.trashOf(sr.armedId))
    },
    function() { sr.click(sr.trashOf(sr.armedId)) },
    function() {
      console.log("HISTORY-AFTER-MIDDLE-DELETE " + (historyTab.selectedId === sr.probeId ? "next-row" : "other:" + historyTab.selectedId)
        + " gone=" + (sr.indexIn(historyTab.rowList, sr.armedId) < 0))
      console.log("HISTORY-NOTE-LABELS " + ["read", "unread", "completed", "reopened"].map(function(label) { return !!sr.findByText(historyTab, label) }).join(" "))
      var button = sr.button(historyTab, "Clear history")
      sr.click(button)
      console.log("HISTORY-AFTER-ONE-CLEAR-CLICK " + (db._writeKind === "") + " " + button.text)
      // The checks after qs exits still read the log, so it is kept aside and
      // put back once the clear and the icon check are done.
      db._write("test", function() { return "CREATE TABLE kept_history AS SELECT * FROM history" }, null)
      sr.click(button)
      db.setStatus(sr.keepId, 1); db.setStatus(sr.keepId, 0)
      db.setStatus(3, 1); db.setStatus(3, 0)
    },
    function() {
      console.log("HISTORY-AFTER-TWO-CLEAR-CLICKS " + historyTab.rowList.length)
      console.log("HISTORY-TODO-ICONS " + !!sr.findByText(historyTab, Icons.boxOn) + " " + !!sr.findByText(historyTab, Icons.boxOff))
      db._write("test", function() { return "DELETE FROM history; INSERT INTO history SELECT * FROM kept_history" }, null)

      var shown = []
      var counting = { show: function(message) { shown.push(message) } }
      itemsTab.toast = counting; historyTab.toast = counting
      db.update(1, "", "")
      itemsTab.toast = toast; historyTab.toast = toast
      // The failure is forced here, so it is not one of the run's write failures.
      sr.writeFailures--
      console.log("ERROR-TOASTS " + shown.filter(function(m) { return m.indexOf("Error") === 0 }).length)
      sr.click(sr.findByText(header, "Items"))
    },
    function() {
      sr.probeId = itemsTab.selectedId
      sr.click(sr.button(sr.editor(), "Delete"))
      sr.click(sr.findByText(header, "History")); sr.click(sr.findByText(header, "Items"))
      console.log("ITEMS-ARM-AFTER-TAB-SWITCH " + panel.activeTab + " " + itemsTab.deleteArmed + " [" + sr.deleteButtonText() + "]")
      sr.click(sr.button(sr.editor(), "Delete"))
      console.log("ITEMS-DELETE-AFTER-TAB-SWITCH " + itemsTab.deleteArmed + " " + (db._writeKind === ""))
    },
    function() { console.log("ITEMS-AFTER-TAB-SWITCH " + (sr.titleOf(sr.probeId) === "missing" ? "deleted" : "kept")) },

    // Each burst clicks and types within 60 ms of the panel opening, then the
    // next step types again, so a late focus reset in between shows up.
    function() { panel.close() },
    function() {
      sr.burst([function() { panel.open() }, function() { sr.click(sr.newButton()) }, function() { sr.click(sr.menuButton("Note")) },
        function() { sr.type("ab"); keys.keyClick(Qt.Key_Tab, Qt.NoModifier, -1) }, function() { sr.type("cd") }])
    },
    function() {
      sr.type("ef")
      console.log("DRAFT-TYPED-ON-OPEN [" + itemsTab.editorTitle + "] [" + itemsTab.editorBody + "] " + sr.focusContext())
      sr.click(sr.button(sr.editor(), "Discard"))
    },
    function() { itemsTab.showAll(); panel.close() },
    function() { sr.burst([function() { panel.open() }, function() { sr.clickSearch() }, function() { sr.type("cof") }]) },
    function() {
      sr.type("fee")
      console.log("SEARCH-TYPED-ON-OPEN [" + itemsTab.searchText + "] " + sr.focusContext() + " " + itemsTab.filterType)
      itemsTab.searchText = ""
    }
  ]

  function indexIn(rows, id) {
    for (var i = 0; i < rows.length; ++i) if (Number(rows[i].id) === Number(id)) return i
    return -1
  }

  function listState() {
    var item = itemsTab.selectedItem
    return [itemsTab.selectedId, item ? item.status : -1, db.items.length, db.totalHistory, panel.activeTab,
      itemsTab.filterType, itemsTab.searchText, itemsTab.draftNew, itemsTab.deleteArmed, sr.focusContext(),
      panel.opened, sr.menuShown()].join("|")
  }
  function historyState() {
    return [historyTab.selectedId, historyTab.rowList.length, db.totalHistory, panel.activeTab,
      !!sr.button(historyTab, "Confirm"), historyTab.clearArmed, panel.opened].join("|")
  }
  function sameState(was, now) { return was === now ? "same" : "changed " + was + " -> " + now }

  property var burstSteps: []
  property int burstIndex: 0
  function burst(list) { sr.burstSteps = list; sr.burstIndex = 0; burstTimer.start() }
  Timer {
    id: burstTimer
    interval: 15
    repeat: true
    onTriggered: {
      if (sr.burstIndex >= sr.burstSteps.length) { burstTimer.stop(); return }
      sr.burstSteps[sr.burstIndex++]()
    }
  }

  function ctrl(keyList) {
    for (var i = 0; i < keyList.length; ++i) keys.keyClick(keyList[i], Qt.ControlModifier, -1)
  }
  function type(text) {
    for (var i = 0; i < text.length; ++i) keys.keyClickChar(text[i], Qt.NoModifier, -1)
  }
  function focusContext() {
    if (sr.findType(itemsTab, "SearchField").activeFocus) return "search"
    if (itemsTab.editorFocused) return itemsTab.draftNew ? "draft" : "editor"
    return "list"
  }
  function draftState() {
    return itemsTab.draftNew + " [" + itemsTab.editorBody + "] " + sr.focusContext() + " toast=" + toast.text
  }
  function click(item) {
    keys.mouseClick(item, item.width / 2, item.height / 2, Qt.LeftButton, Qt.NoModifier, -1)
  }
  function hover(item) { keys.mouseMove(item, item.width / 2, item.height / 2, -1, Qt.NoButton, Qt.NoModifier) }
  function clickSearch() { sr.click(sr.findType(itemsTab, "SearchField")) }
  function editor() { return sr.findType(itemsTab, "EditorPane") }
  function clickTitle() { sr.click(sr.findType(sr.editor(), "Field")) }
  function firstRow() { return sr.findType(itemsTab, "ItemRow") }
  function button(item, text) {
    return sr.findWhere(item, function(it) { return String(it).indexOf("ActionButton") === 0 && it.visible && it.text === text })
  }
  function deleteButtonText() {
    var b = sr.findWhere(sr.editor(), function(it) { return String(it).indexOf("ActionButton") === 0 && it.iconText === Icons.trash })
    return b ? b.text : "none"
  }
  function newButton() {
    return sr.findWhere(header, function(it) { return String(it).indexOf("ActionButton") === 0 && String(it.text).indexOf("New") === 0 })
  }
  // A Popup is not an Item child, so it is looked up through `data`.
  function newMenu(obj) {
    obj = obj || header
    if (/^(QQuick)?Popup[_(]/.test(String(obj))) return obj
    var kids = obj.data || []
    for (var i = 0; i < kids.length; ++i) {
      var hit = sr.newMenu(kids[i])
      if (hit) return hit
    }
    return null
  }
  function menuShown() { var menu = sr.newMenu(); return !!menu && menu.opened }
  function menuButton(label) {
    var menu = sr.newMenu()
    return menu && menu.opened ? sr.button(menu.contentItem, label) : null
  }
  function historyRow(id) {
    return sr.findWhere(historyTab, function(it) {
      return String(it).indexOf("QQuickRectangle") === 0 && !!it.modelData && Number(it.modelData.id) === Number(id)
    })
  }
  function trashOf(id) {
    var row = sr.historyRow(id)
    return row ? sr.findWhere(row, function(it) { return String(it).indexOf("ActionButton") === 0 && it.iconText === Icons.trash }) : null
  }
  function findWhere(item, match) {
    if (!item) return null
    if (match(item)) return item
    for (var i = 0; i < item.children.length; ++i) {
      var hit = sr.findWhere(item.children[i], match)
      if (hit) return hit
    }
    return null
  }
  function findType(item, prefix) {
    return sr.findWhere(item, function(it) { return String(it).indexOf(prefix) === 0 })
  }
  function findByText(item, text) {
    return sr.findWhere(item, function(it) { return it.text === text })
  }

  function highlighted(item) {
    var ids = []
    if (String(item).indexOf("ItemRow") === 0 && item.selected) ids.push(item.item.id)
    for (var i = 0; i < item.children.length; ++i) ids = ids.concat(sr.highlighted(item.children[i]))
    return ids
  }

  Data.Db {
    id: testDb
    Component.onCompleted: testDb.init()
  }
  Loader {
    source: Qt.resolvedUrl("Panel.qml")
    onLoaded: {
      item.db = testDb
      var content = null
      for (var i = 0; i < item.data.length; ++i)
        if (String(item.data[i]).indexOf("KeyboardPanel") === 0) content = item.data[i].contentItem
      sr.header = sr.findType(content, "PanelHeader")
      sr.toast = sr.findType(content, "Toast")
      sr.itemsTab = sr.findType(content, "ItemsTab")
      sr.historyTab = sr.findType(content, "HistoryTab")
      sr.panel = item
      item.open()
    }
  }
  Connections {
    target: sr.db
    function onItemsUpdated() { if (!sr.started) { sr.started = true; stepTimer.start() } }
    function onFailed(message) { sr.writeFailures++; console.log("DB-FAILED " + message) }
  }
  Timer {
    id: stepTimer
    interval: 600
    repeat: true
    onTriggered: {
      if (sr.stepIndex >= sr.steps.length) { console.log("WRITE-FAILURES " + sr.writeFailures); Qt.exit(0); return }
      sr.steps[sr.stepIndex++]()
    }
  }
  TestEvent { id: keys }
}
QML

run_qs > "$cfg_dir/qs.log" 2>&1 || { cat "$cfg_dir/qs.log"; echo "qs exited non-zero"; exit 2; }

checks=0
failures=0
pass() { checks=$((checks + 1)); echo "ok   $1"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); echo "FAIL $1"; }
expect() {
  local what="$1" sql="$2" want="$3" got
  if ! got="$(sqlite3 "$db" "$sql" 2>&1)"; then fail "$what: sqlite3 error: $got"
  elif [[ "$got" == "$want" ]]; then pass "$what"
  else fail "$what: want '$want', got '$got'"; fi
}
log_file="$cfg_dir/qs.log"
logged() {
  local what="$1" pattern="$2"
  if grep -qE "$pattern" "$log_file"; then pass "$what"
  else fail "$what: $(grep -oE "${pattern%% *}.*" "$log_file" | head -3 | tr '\n' ';')"; fi
}

expect "edit is saved to the item it was typed in when another row is clicked" \
  "SELECT COUNT(*) FROM history WHERE action = 'edited' AND title = 'EDITED-RENEW'" "1"
expect "the clicked row keeps its own title" \
  "SELECT title FROM items WHERE id = 3" "Reply to upstream PR review"
logged "only the clicked row is highlighted after the save reloads the list" "HIGHLIGHTED 3$"
expect "edit is saved when focus moves to the search field" \
  "SELECT title FROM items WHERE id = 4" "EDITED-COFFEE"
logged "focus stays in the search field, and the edit is already saved before any search" "FOCUS-AFTER-SEARCH search TITLE4 EDITED-COFFEE$"
expect "committing a draft leaves the previously open item untouched" \
  "SELECT title FROM items WHERE id = 5" "Backup scratchpad.db"
expect "a draft committed with its Save button is saved once" \
  "SELECT COUNT(*) FROM items WHERE title = 'DRAFT-BY-SAVE'" "1"
expect "draft is saved when the panel closes" \
  "SELECT COUNT(*) FROM items WHERE title = 'DRAFT-ON-CLOSE'" "1"
expect "discard leaves the item untouched" \
  "SELECT title FROM items WHERE id = 1" "Ideas for the panel"
expect "convert flips the type and keeps the status" \
  "SELECT type || ':' || status FROM items WHERE id = 5" "note:1"
expect "convert is logged in history" \
  "SELECT COUNT(*) FROM history WHERE action = 'converted' AND title = 'Backup scratchpad.db'" "1"

expect "an emptied title keeps the saved title and still saves the body" \
  "SELECT title || '|' || body FROM items WHERE id = 3" "Reply to upstream PR review|BODY-KEPT"
logged "deleting the last row selects the row above it" "AFTER-DELETE-LAST previous-row$"
logged "a draft survives a reload of an empty filtered list" "DRAFT-AFTER-RELOAD true DRAFT-IN-EMPTY-LIST$"
expect "that draft is saved" "SELECT COUNT(*) FROM items WHERE title = 'DRAFT-IN-EMPTY-LIST'" "1"
expect "three writes fired in one tick all land (edit, convert, toggle)" \
  "SELECT (SELECT body FROM items WHERE id = 1) || '|' || (SELECT type || ':' || status FROM items WHERE id = 2)" "QUEUED-BODY|note:1"
logged "an item added outside the filter does not hijack the selection later" "SELECTION-AFTER-WIDENING kept$"
logged "a draft opened in the same tick as a discard stays open" "DRAFT-AFTER-DISCARD true$"

logged "neither tab has a hint bar" "HINT-BARS true true$"
logged "the editor reaches the bottom of the Items tab" "EDITOR-REACHES-BOTTOM true$"
logged "New opens a menu with Note and Todo, opens no draft by itself and has no shortcut tooltip" \
  "NEW-MENU true true true draft=false tooltip=\[\]$"
logged "Todo in the menu opens a todo draft with its title focused and closes the menu" "NEW-TODO-DRAFT true todo draft menu=false$"
logged "Note in the menu commits the open draft and opens an empty note draft" "NEW-NOTE-DRAFT true note \[\] draft menu=false$"
expect "the todo draft opened from the menu is saved as a todo" "SELECT type FROM items WHERE title = 'menu todo'" "todo"
logged "a click outside the open menu closes it" "MENU-AFTER-OUTSIDE-CLICK false 1$"
logged "Enter in a draft body inserts a new line" "ENTER-IN-DRAFT-BODY true draft$"
logged "Esc on a draft with a body and no title closes the panel and keeps the draft, with the warning" \
  "UNTITLED-DRAFT-AFTER-ESC false true \[orphan body\] .* toast=New item needs a title$"
logged "reopening the panel shows that draft again, focused" "UNTITLED-DRAFT-AFTER-REOPEN true \[orphan body\] draft"
logged "clicking a row keeps that draft open and its title focused" \
  "UNTITLED-DRAFT-AFTER-ROW-CLICK true \[orphan body\] draft toast=New item needs a title$"
logged "switching to History and back shows that draft again, focused" \
  "UNTITLED-DRAFT-AFTER-TAB-SWITCH true \[orphan body\] draft"
logged "Todo in the menu on that draft keeps it and its body, focused, as a todo" \
  "UNTITLED-DRAFT-AFTER-NEW true \[orphan body\] draft .* todo$"
logged "the Discard button throws that draft away" "UNTITLED-DRAFT-AFTER-DISCARD false list$"
expect "a draft without a title never reaches the db" \
  "SELECT COUNT(*) FROM items WHERE body LIKE 'orphan body%'" "0"
logged "Esc on an empty draft closes the panel and drops it without the warning" "EMPTY-DRAFT-AFTER-ESC false false toast=\[\]$"

logged "Tab in the title moves to the body" "TAB-IN-TITLE true$"
logged "Shift+Tab in the body moves to the title" "SHIFT-TAB-IN-BODY true$"
logged "Enter in the title moves to the body" "ENTER-IN-TITLE true$"
logged "Enter in the body inserts a new line and stays in the body" "ENTER-IN-BODY true true true$"
logged "Shift+Esc in the editor keeps the panel open and the edit unsaved" "SHIFT-ESC-IN-EDITOR true true true$"
logged "Ctrl+T in a draft title leaves the title and the type alone" "CTRL-T-IN-DRAFT-TITLE \[tomar\] note$"
logged "Ctrl+T in a draft body leaves the body and the type alone" "CTRL-T-IN-DRAFT-BODY \[\] note$"
logged "Shift+Esc in a draft keeps the panel open and the draft" "SHIFT-ESC-IN-DRAFT true true \[tomar\]$"
logged "2 in a draft title is typed as text" "TWO-IN-TITLE 0 \[tomar2\]$"
logged "1 in the search field is typed as text" "ONE-IN-SEARCH 0 \[1\] search$"

logged "no list key moves, opens, toggles, deletes, searches, filters or switches tabs" "LIST-KEYS same$"
logged "no History key moves, arms, deletes, clears or switches tabs" "HISTORY-KEYS same$"
logged "Esc with Ctrl, Alt, Super or Shift leaves the panel open in History" "ESC-WITH-MODIFIER-IN-HISTORY true$"
logged "Esc in History closes the panel" "ESC-IN-HISTORY false$"
logged "Esc with Ctrl, Alt, Super or Shift leaves the panel open in the list" "ESC-WITH-MODIFIER-IN-LIST true$"
logged "Esc in the list closes the panel" "ESC-IN-LIST false$"
logged "Esc in the search field closes the panel" "ESC-IN-SEARCH false$"
logged "Esc in the editor closes the panel" "ESC-IN-EDITOR false$"
expect "and the close commits the edit" "SELECT title FROM items WHERE id = 2" "ESC-COMMITS"
logged "clicking Todos filters the list" "FILTER-AFTER-TODOS-CLICK todo notes=0$"

logged "Delete arms on the first click, and selecting another row cancels it" "ITEMS-ARMED-AFTER-MOVE true false true$"
logged "that click does not delete the item" "ITEMS-DELETE-AFTER-MOVING-BACK kept$"
logged "the trash shows on the hovered History row only" "TRASH-ON-HOVER true false$"
logged "the first click on the trash arms it and reads Confirm, deleting nothing" "TRASH-ARMED true \[Confirm\] rows=[0-9]+$"
logged "selecting another History row cancels the armed trash" "TRASH-AFTER-SELECT \[\] [0-9]+$"
logged "the trash arms again after that" "TRASH-REARMED \[Confirm\]$"
logged "switching tabs cancels the armed trash" "TRASH-AFTER-TAB-SWITCH \[\] [0-9]+$"
logged "a second click on Confirm deletes the entry and selects the next one" "HISTORY-AFTER-MIDDLE-DELETE next-row gone=true$"
logged "a note marked read or unread shows read and unread in History, never completed or reopened" \
  "HISTORY-NOTE-LABELS true true false false$"
logged "one click on Clear history only arms it" "HISTORY-AFTER-ONE-CLEAR-CLICK true Confirm$"
logged "a second click on Clear history clears it" "HISTORY-AFTER-TWO-CLEAR-CLICKS 4$"
logged "a completed todo shows a checked box in History, a reopened one an empty box" "HISTORY-TODO-ICONS true true$"
logged "a failed write shows one error toast" "ERROR-TOASTS 1$"
logged "Delete, then clicking History and Items, leave no delete armed" "ITEMS-ARM-AFTER-TAB-SWITCH 0 false \[Delete\]$"
logged "a Delete click after coming back only arms the delete again" "ITEMS-DELETE-AFTER-TAB-SWITCH true true$"
logged "that click leaves the item in place" "ITEMS-AFTER-TAB-SWITCH kept$"
logged "a draft opened and typed right after opening keeps its title and body, and focus stays in the body" \
  "DRAFT-TYPED-ON-OPEN \[ab\] \[cdef\] draft$"
logged "a search typed right after opening keeps its text and focus" "SEARCH-TYPED-ON-OPEN \[coffee\] search all$"
logged "no write was rejected during the whole run" "WRITE-FAILURES 0$"

# The first qs run has no time left under its timeout, so the history count
# gets its own run against a log longer than the 500 rows historySql() reads.
sqlite3 "$db" "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 600)
  INSERT INTO history (type, title, action, ts) SELECT 'todo', 'Bulk ' || i, 'added', $now - 200000 - i FROM n"
history_total="$(sqlite3 "$db" "SELECT COUNT(*) FROM history")"
cat > "$cfg_dir/shell.qml" <<'QML'
import QtQuick
import Quickshell
import "data" as Data

ShellRoot {
  id: sr
  property bool countsSeen: false
  property bool historySeen: false

  function findByText(item, text) {
    if (item.text === text) return item
    for (var i = 0; i < item.children.length; ++i) {
      var hit = sr.findByText(item.children[i], text)
      if (hit) return hit
    }
    return null
  }
  function report() {
    if (!sr.countsSeen || !sr.historySeen) return
    var label = sr.findByText(header.item, "History")
    console.log("HISTORY-COUNT " + label.parent.children[2].text)
    Qt.exit(0)
  }

  Data.Db {
    id: countDb
    Component.onCompleted: countDb.init()
    onCountsUpdated: { sr.countsSeen = true; Qt.callLater(sr.report) }
    onHistoryUpdated: { sr.historySeen = true; Qt.callLater(sr.report) }
  }
  Loader {
    id: header
    source: Qt.resolvedUrl("ui/PanelHeader.qml")
    onLoaded: item.db = countDb
  }
}
QML
run_qs > "$cfg_dir/qs-count.log" 2>&1 || { cat "$cfg_dir/qs-count.log"; echo "qs exited non-zero"; exit 2; }
if (( history_total > 500 )) && grep -qE "HISTORY-COUNT $history_total$" "$cfg_dir/qs-count.log"; then
  pass "the History tab counts all $history_total entries, past the 500 it lists"
else
  fail "the History tab count: want $history_total, got '$(grep -oE 'HISTORY-COUNT.*' "$cfg_dir/qs-count.log" | head -1)'"
fi

# A third run for writes that fail or land on a row removed under the editor.
# The triggers make any write of a title starting with FAIL- fail in sqlite3,
# the same path a locked database takes after its 5 s timeout.
sqlite3 "$db" "INSERT INTO items (id, type, title, body, status, created_at, updated_at) VALUES
  (201, 'note', 'Dirty then deleted', '', 0, $now, $now),
  (202, 'note', 'Removed by a script', '', 0, $now, $now),
  (203, 'todo', 'Edit that fails', 'saved body', 0, $now, $now),
  (204, 'note', 'Removed under a filter', '', 0, $now, $now),
  (205, 'note', 'Fails on close', '', 0, $now, $now),
  (206, 'note', 'Fails behind a draft', '', 0, $now, $now),
  (207, 'note', 'Hidden when it fails', '', 0, $now, $now),
  (208, 'note', 'Removed behind a draft', '', 0, $now, $now),
  (209, 'todo', 'Toggled back by its button', '', 1, $now, $now);
CREATE TRIGGER fail_add BEFORE INSERT ON items WHEN NEW.title LIKE 'FAIL-%'
  BEGIN SELECT RAISE(ABORT, 'forced failure'); END;
CREATE TRIGGER fail_edit BEFORE UPDATE OF title ON items WHEN NEW.title LIKE 'FAIL-%'
  BEGIN SELECT RAISE(ABORT, 'forced failure'); END;"
cat > "$cfg_dir/shell.qml" <<'QML'
import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import "data" as Data

ShellRoot {
  id: sr
  property int stepIndex: 0
  property bool started: false
  property var toasts: []
  property var panel: null
  property var itemsTab: null
  property var editor: null
  readonly property var db: sr.itemsTab ? sr.itemsTab.db : null

  function has(text) { return sr.toasts.some(function(m) { return m.indexOf(text) >= 0 }) }
  function toastsSeen(label) {
    console.log(label + "-TOASTS [" + sr.toasts.join("|") + "]")
    return "saved=" + sr.has("Saved") + " error=" + sr.has("Error") + " added=" + sr.has("Added")
      + " removed=" + sr.has("Item removed elsewhere")
  }
  function editorState() {
    return itemsTab.draftNew + " [" + itemsTab.editorTitle + "] [" + itemsTab.editorBody + "] dirty=" + editor.dirty
  }
  function focusContext() {
    if (sr.findType(itemsTab, "SearchField").activeFocus) return "search"
    if (itemsTab.editorFocused) return itemsTab.draftNew ? "draft" : "editor"
    return "list"
  }
  function otherId() { return itemsTab.itemList[0].id === 203 ? itemsTab.itemList[1].id : itemsTab.itemList[0].id }
  function clickTitle() { sr.click(sr.findType(sr.editor, "Field")) }
  function pickFilter(label) { sr.click(sr.findByText(itemsTab, label)) }

  readonly property var steps: [
    function() { itemsTab.pickItem(209) },
    function() {
      var button = sr.findByText(editor, "Mark pending")
      console.log("TOGGLE-BUTTON " + (button !== null))
      sr.toasts = []
      if (button) sr.click(button)
    },
    function() { console.log("TOGGLE-TOAST [" + sr.toasts.join("|") + "]") },

    function() { itemsTab.pickItem(201); sr.clickTitle() },
    function() { itemsTab.editorTitle = "DIRTY-DELETE"; sr.toasts = []; sr.click(sr.findByText(editor, "Delete")) },
    function() { sr.click(sr.findByText(editor, "Confirm")) },
    function() { console.log("DELETE-DIRTY " + sr.toastsSeen("DELETE-DIRTY") + " deleted=" + sr.has("Deleted")) },

    function() { itemsTab.pickItem(202); sr.clickTitle() },
    function() {
      itemsTab.editorBody = "TYPED-BEFORE-REMOVAL"; sr.toasts = []
      db.fromScript(function() { return db.deleteItem(202) })
    },
    function() {
      console.log("REMOVED-ELSEWHERE " + sr.toastsSeen("REMOVED-ELSEWHERE") + " holds-removed=" + (editor.editingId === 202)
        + " " + sr.focusContext())
    },

    function() { itemsTab.focusList(); itemsTab.startNew("note") },
    function() {
      itemsTab.editorTitle = "FAIL-ADD"; itemsTab.editorBody = "draft body kept"; sr.toasts = []
      itemsTab.commitEditor(true)
      console.log("FAILING-ADD-AT-COMMIT " + sr.toastsSeen("FAILING-ADD-AT-COMMIT"))
    },
    function() {
      console.log("FAILED-ADD " + sr.editorState() + " " + sr.focusContext() + " " + sr.toastsSeen("FAILED-ADD"))
      itemsTab.discardEditor()
    },
    function() { itemsTab.startNew("todo") },
    function() {
      itemsTab.editorTitle = "GOOD-ADD"; sr.toasts = []
      itemsTab.commitEditor(true)
      console.log("GOOD-ADD-AT-COMMIT " + sr.toastsSeen("GOOD-ADD-AT-COMMIT"))
    },
    function() { console.log("GOOD-ADD-LATER " + sr.has("Added todo — GOOD-ADD")) },

    function() { itemsTab.pickItem(203); sr.clickTitle() },
    function() {
      itemsTab.editorTitle = "FAIL-EDIT"; itemsTab.editorBody = "edit body kept"; sr.toasts = []
      itemsTab.pickItem(sr.otherId())
    },
    function() {
      console.log("FAILED-EDIT-AFTER-MOVE " + (itemsTab.selectedId === 203) + " " + sr.editorState() + " "
        + sr.toastsSeen("FAILED-EDIT-AFTER-MOVE"))
      itemsTab.discardEditor(); sr.clickTitle()
    },
    function() {
      itemsTab.editorTitle = "FAIL-EDIT-AGAIN"; sr.toasts = []
      itemsTab.commitEditor(true)
    },
    function() {
      console.log("FAILED-EDIT-IN-PLACE " + (itemsTab.selectedId === 203) + " " + sr.editorState() + " "
        + sr.toastsSeen("FAILED-EDIT-IN-PLACE"))
      itemsTab.discardEditor(); sr.pickFilter("Notes")
    },

    function() { itemsTab.pickItem(204); sr.clickTitle() },
    function() {
      itemsTab.editorBody = "TYPED-UNDER-FILTER"; sr.toasts = []
      db.fromScript(function() { return db.deleteItem(204) })
    },
    function() {
      console.log("REMOVED-UNDER-FILTER " + db.listFilter + " " + sr.toastsSeen("REMOVED-UNDER-FILTER") + " "
        + sr.focusContext())
      sr.pickFilter("All")
    },

    function() { itemsTab.pickItem(205); sr.clickTitle() },
    function() {
      itemsTab.editorTitle = "FAIL-ON-CLOSE"; itemsTab.editorBody = "typed before close"; sr.toasts = []
      panel.close()
    },
    function() { panel.open() },
    function() {
      console.log("FAILED-ON-CLOSE " + (itemsTab.selectedId === 205) + " " + sr.editorState() + " "
        + sr.toastsSeen("FAILED-ON-CLOSE"))
      itemsTab.discardEditor()
    },

    function() { itemsTab.pickItem(206); sr.clickTitle() },
    function() {
      itemsTab.editorTitle = "FAIL-BEHIND-DRAFT"; sr.toasts = []
      itemsTab.commitEditor(true); itemsTab.startNew("note"); itemsTab.editorTitle = "DRAFT-OVER-FAILURE"
    },
    function() {
      console.log("FAILED-BEHIND-DRAFT " + sr.editorState() + " " + sr.toastsSeen("FAILED-BEHIND-DRAFT"))
      itemsTab.commitEditor(true)
    },
    function() {},
    function() {
      console.log("RESTORED-AFTER-DRAFT " + (itemsTab.selectedId === 206) + " " + sr.editorState())
      itemsTab.discardEditor(); locker.running = true
    },

    function() { itemsTab.pickItem(207); sr.clickTitle() },
    function() {
      itemsTab.editorTitle = "LOCKED-EDIT"; sr.toasts = []
      sr.click(sr.findType(itemsTab, "SearchField")); itemsTab.searchText = "matches no item"
    },
    function() { console.log("HIDDEN-BEFORE-FAILURE " + itemsTab.itemList.length) },
    function() {}, function() {}, function() {}, function() {}, function() {},
    function() {}, function() {}, function() {}, function() {},
    function() {
      console.log("FAILED-WHILE-HIDDEN " + (itemsTab.selectedId === 207) + " [" + itemsTab.searchText + "] "
        + sr.editorState() + " " + sr.toastsSeen("FAILED-WHILE-HIDDEN"))
      itemsTab.discardEditor()
    },

    function() { itemsTab.pickItem(208); sr.clickTitle() },
    function() {
      itemsTab.editorTitle = "FAIL-REMOVED-BEHIND-DRAFT"
      itemsTab.commitEditor(true); itemsTab.startNew("note"); itemsTab.editorTitle = "DRAFT-OVER-REMOVAL"
    },
    function() {
      console.log("QUEUED-BEHIND-DRAFT " + sr.editorState() + " error=" + sr.has("Error"))
      sr.toasts = []
      db.fromScript(function() { return db.deleteItem(208) })
    },
    function() { itemsTab.commitEditor(true) },
    function() {},
    function() {
      console.log("REMOVED-BEHIND-DRAFT " + sr.editorState() + " " + sr.toastsSeen("REMOVED-BEHIND-DRAFT"))
    }
  ]

  // Unlike the triggers, a real lock lets the list reload before the edit
  // fails: BEGIN IMMEDIATE blocks writers past their 5 s timeout, not readers.
  Process {
    id: locker
    command: ["sh", "-c", "(printf 'BEGIN IMMEDIATE;\\n'; sleep 7; printf 'COMMIT;\\n') | sqlite3 \"$1\"",
      "sh", sr.db ? sr.db.dbPath : ""]
  }

  function click(item) {
    keys.mouseClick(item, item.width / 2, item.height / 2, Qt.LeftButton, Qt.NoModifier, -1)
  }
  function findType(item, prefix) {
    if (String(item).indexOf(prefix) === 0) return item
    for (var i = 0; i < item.children.length; ++i) {
      var hit = sr.findType(item.children[i], prefix)
      if (hit) return hit
    }
    return null
  }
  function findByText(item, text) {
    if (item.text === text) return item
    for (var i = 0; i < item.children.length; ++i) {
      var hit = sr.findByText(item.children[i], text)
      if (hit) return hit
    }
    return null
  }

  Data.Db {
    id: testDb
    Component.onCompleted: testDb.init()
  }
  Loader {
    source: Qt.resolvedUrl("Panel.qml")
    onLoaded: {
      item.db = testDb
      sr.panel = item
      var content = null
      for (var i = 0; i < item.data.length; ++i)
        if (String(item.data[i]).indexOf("KeyboardPanel") === 0) content = item.data[i].contentItem
      var toast = sr.findType(content, "Toast")
      sr.itemsTab = sr.findType(content, "ItemsTab")
      sr.editor = sr.findType(sr.itemsTab, "EditorPane")
      sr.itemsTab.toast = { show: function(message, urgent) { sr.toasts.push(String(message)); toast.show(message, urgent) } }
      item.open()
    }
  }
  Connections {
    target: sr.db
    function onItemsUpdated() { if (!sr.started) { sr.started = true; stepTimer.start() } }
  }
  Timer {
    id: stepTimer
    interval: 600
    repeat: true
    onTriggered: {
      if (sr.stepIndex >= sr.steps.length) { Qt.exit(0); return }
      sr.steps[sr.stepIndex++]()
    }
  }
  TestEvent { id: keys }
}
QML
log_file="$cfg_dir/qs-writes.log"
run_qs > "$log_file" 2>&1 || { cat "$log_file"; echo "qs exited non-zero"; exit 2; }

logged "a completed todo's toggle button says Mark pending" "TOGGLE-BUTTON true$"
logged "its toast repeats the button's words" "TOGGLE-TOAST \[Marked pending — Toggled back by its button\]$"
expect "the button sets the todo back to pending" "SELECT status FROM items WHERE id = 209" "0"
logged "deleting a dirty item with the mouse shows Deleted, never Saved or an error" \
  "DELETE-DIRTY saved=false error=false added=false removed=false deleted=true$"
logged "an item removed by a script while being edited shows Item removed elsewhere and returns to the list" \
  "REMOVED-ELSEWHERE saved=false error=false added=false removed=true holds-removed=false list$"
logged "with a filter on, an item removed by a script while being edited shows Item removed elsewhere" \
  "REMOVED-UNDER-FILTER note saved=false error=false added=false removed=true list$"
logged "Added does not show when a draft is committed" "FAILING-ADD-AT-COMMIT saved=false error=false added=false"
logged "a failed add puts the draft back in the editor, focused, with the error and no Added" \
  "FAILED-ADD true \[FAIL-ADD\] \[draft body kept\] dirty=false draft saved=false error=true added=false"
logged "Added waits for the database on a good add too" "GOOD-ADD-AT-COMMIT saved=false error=false added=false"
logged "Added shows once the database confirms the add" "GOOD-ADD-LATER true$"
expect "the good add is saved" "SELECT COUNT(*) FROM items WHERE title = 'GOOD-ADD'" "1"
logged "a failed edit after moving to another row reselects the item with the typed text, unsaved" \
  "FAILED-EDIT-AFTER-MOVE true false \[FAIL-EDIT\] \[edit body kept\] dirty=true saved=false error=true"
logged "a failed edit that stays on the item keeps the typed text, unsaved" \
  "FAILED-EDIT-IN-PLACE true false \[FAIL-EDIT-AGAIN\] \[saved body\] dirty=true saved=false error=true"
logged "an edit that fails after the panel closes is still in the editor when it reopens" \
  "FAILED-ON-CLOSE true false \[FAIL-ON-CLOSE\] \[typed before close\] dirty=true saved=false error=true"
logged "an edit that fails while a draft is open leaves the draft alone" \
  "FAILED-BEHIND-DRAFT true \[DRAFT-OVER-FAILURE\] \[\] dirty=false saved=false error=true"
logged "that failed edit comes back once the draft is committed" \
  "RESTORED-AFTER-DRAFT true false \[FAIL-BEHIND-DRAFT\] \[\] dirty=true$"
logged "the search hides the edited item before its write fails" "HIDDEN-BEFORE-FAILURE 0$"
logged "an edit that fails while the search hides its item clears the search and comes back" \
  "FAILED-WHILE-HIDDEN true \[\] false \[LOCKED-EDIT\] \[\] dirty=true saved=false error=true"
logged "an edit that fails behind a draft waits there with its error shown" \
  "QUEUED-BEHIND-DRAFT true \[DRAFT-OVER-REMOVAL\] \[\] dirty=false error=true"
logged "a failed edit whose item a script removes while it waits behind a draft shows Item removed elsewhere" \
  "REMOVED-BEHIND-DRAFT false \[DRAFT-OVER-REMOVAL\] \[\] dirty=false saved=false error=false added=true removed=true"

echo "behavior: $checks checks, $failures failed"
exit $(( failures > 0 ))
