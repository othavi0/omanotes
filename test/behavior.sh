#!/usr/bin/env bash
# Drives the real Panel.qml against a seeded sqlite db, offscreen, then asserts
# on the rows that reached the db. Covers the editor's save-on-leave contract.

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
  function fittedContentWidth(width) { return width }
  function fittedContentHeight(height) { return height }
  implicitWidth: contentWidth
  implicitHeight: contentHeight
  visible: open
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
  property int hiddenId: -1
  property int probeId: -1
  property int probeRows: -1
  property var panel: null
  property var mainTab: null
  property var historyTab: null
  property var header: null
  property var toast: null
  readonly property var db: sr.mainTab ? sr.mainTab.db : null

  function titleOf(id) {
    for (var i = 0; i < db.items.length; ++i) if (Number(db.items[i].id) === id) return db.items[i].title
    return "missing"
  }
  readonly property var steps: [
    function() { mainTab.pickItem(2); mainTab.focusEditor() },
    function() { mainTab.editorTitle = "EDITED-RENEW"; mainTab.pickItem(3) },
    function() { mainTab.commitIfDirty() },
    function() { console.log("HIGHLIGHTED " + sr.highlighted(mainTab).join(",")) },

    function() { mainTab.pickItem(4); mainTab.focusEditor() },
    function() { mainTab.editorTitle = "EDITED-COFFEE"; mainTab.focusSearch() },
    function() { console.log("FOCUS-AFTER-SEARCH " + mainTab.focusContext + " TITLE4 " + sr.titleOf(4)) },
    function() { mainTab.searchText = "panel" },
    function() { mainTab.searchText = "" },

    function() { mainTab.startNew("note") },
    function() { mainTab.editorTitle = "DRAFT-ON-CLOSE"; panel.close() },
    function() { panel.open() },

    function() { mainTab.pickItem(5); mainTab.focusEditor() },
    function() { mainTab.startNew("todo") },
    function() { mainTab.editorTitle = "DRAFT-BY-ENTER"; mainTab.commitEditor() },

    function() { mainTab.pickItem(1); mainTab.focusEditor() },
    function() { mainTab.editorTitle = "DISCARDED"; mainTab.discardEditor() },
    function() { mainTab.commitIfDirty() },

    function() { mainTab.pickItem(5); mainTab.convertSelected() },

    function() { mainTab.pickItem(3); mainTab.focusEditor() },
    function() { mainTab.editorTitle = ""; mainTab.editorBody = "BODY-KEPT"; mainTab.pickItem(1) },

    function() { sr.lastId = db.items[db.items.length - 1].id; sr.beforeLastId = db.items[db.items.length - 2].id; mainTab.pickItem(sr.lastId) },
    function() { mainTab.armDelete(); mainTab.armDelete() },
    function() { console.log("AFTER-DELETE-LAST " + (mainTab.selectedId === sr.beforeLastId ? "previous-row" : "other:" + mainTab.selectedId)) },

    function() { mainTab.searchText = "zzz_no_match" },
    function() { mainTab.startNew("note") },
    function() { mainTab.editorTitle = "DRAFT-IN-EMPTY-LIST"; db.load() },
    function() { console.log("DRAFT-AFTER-RELOAD " + mainTab.draftNew + " " + mainTab.editorTitle) },
    function() { mainTab.commitEditor(true) },
    function() { mainTab.searchText = "" },

    function() { mainTab.pickItem(1); mainTab.focusEditor() },
    function() { mainTab.editorBody = "QUEUED-BODY"; mainTab.pickItem(2); mainTab.convertSelected(); mainTab.toggleStatus() },

    function() { mainTab.filterType = "todo"; mainTab.searchText = "upstream" },
    function() { sr.keepId = mainTab.selectedId; mainTab.startNew("note") },
    function() { mainTab.editorTitle = "NOTE-HIDDEN-BY-FILTER"; mainTab.commitEditor(true) },
    function() { mainTab.filterType = "all"; mainTab.searchText = "" },
    function() { console.log("SELECTION-AFTER-WIDENING " + (mainTab.selectedId === sr.keepId ? "kept" : "hijacked:" + mainTab.selectedId)) },

    function() { mainTab.pickItem(4); mainTab.focusEditor() },
    function() { mainTab.editorBody = "THROWN-AWAY"; mainTab.discardEditor(); mainTab.startNew("note") },
    function() { console.log("DRAFT-AFTER-DISCARD " + mainTab.draftNew); mainTab.discardEditor() },

    function() { mainTab.focusList(); keys.keyClickChar("n", Qt.NoModifier, -1) },
    function() { keys.keyClick(Qt.Key_Tab, Qt.NoModifier, -1); sr.type("orphan body") },
    function() { keys.keyClick(Qt.Key_Escape, Qt.NoModifier, -1) },
    function() {
      console.log("UNTITLED-DRAFT-AFTER-ESC " + sr.draftState())
      console.log("UNTITLED-DRAFT-HINTS " + sr.hintKeys())
      keys.keyClick(Qt.Key_Tab, Qt.NoModifier, -1)
    },
    function() { keys.keyClick(Qt.Key_Return, Qt.NoModifier, -1) },
    function() { console.log("UNTITLED-DRAFT-AFTER-ENTER " + sr.draftState()); sr.click(sr.firstRow(mainTab)) },
    function() { console.log("UNTITLED-DRAFT-AFTER-ROW-CLICK " + sr.draftState()); panel.close() },
    function() { panel.open() },
    function() { console.log("UNTITLED-DRAFT-AFTER-REOPEN " + sr.draftState()); sr.click(sr.findByText(header, "History")) },
    function() { sr.click(sr.findByText(header, "Items")) },
    function() { console.log("UNTITLED-DRAFT-AFTER-TAB-SWITCH " + sr.draftState()); sr.click(sr.findByText(header, "New")) },
    function() { console.log("UNTITLED-DRAFT-AFTER-NEW " + sr.draftState()); sr.clickSearch() },
    function() { console.log("SEARCH-HINTS-WITH-DRAFT " + sr.hintKeys()); keys.keyClick(Qt.Key_Escape, Qt.NoModifier, -1) },
    function() { console.log("UNTITLED-DRAFT-AFTER-SEARCH-ESC " + sr.draftState()); sr.clickSearch() },
    function() { keys.keyClick(Qt.Key_Return, Qt.NoModifier, -1) },
    function() { console.log("UNTITLED-DRAFT-AFTER-SEARCH-ENTER " + sr.draftState()); sr.clickSearch() },
    function() { keys.keyClick(Qt.Key_Tab, Qt.NoModifier, -1) },
    function() { console.log("UNTITLED-DRAFT-AFTER-SEARCH-TAB " + sr.draftState()); sr.hiddenId = mainTab.selectedId; sr.type("dd") },
    function() {
      console.log("HIDDEN-ROW-AFTER-DD " + (sr.titleOf(sr.hiddenId) === "missing" ? "deleted" : "kept"))
      keys.keyClick(Qt.Key_Backspace, Qt.NoModifier, -1); keys.keyClick(Qt.Key_Backspace, Qt.NoModifier, -1)
    },
    function() { keys.keyClick(Qt.Key_Escape, Qt.ShiftModifier, -1) },
    function() {
      console.log("UNTITLED-DRAFT-AFTER-SHIFT-ESC " + mainTab.draftNew + " " + mainTab.focusContext)
      toast.text = ""; keys.keyClickChar("n", Qt.NoModifier, -1)
    },
    function() { keys.keyClick(Qt.Key_Escape, Qt.NoModifier, -1) },
    function() {
      console.log("EMPTY-DRAFT-AFTER-ESC " + mainTab.draftNew + " " + mainTab.focusContext + " toast=[" + toast.text + "]")
      mainTab.focusList(); keys.keyClickChar("n", Qt.NoModifier, -1)
    },
    function() { sr.type("first draft") },
    function() { sr.click(sr.findByText(header, "New")) },
    function() { console.log("AFTER-NEW-CLICK " + mainTab.draftNew + " [" + mainTab.editorTitle + "]") },
    function() { mainTab.discardEditor() },

    function() { sr.probeId = mainTab.itemList[1].id; mainTab.pickItem(sr.probeId); sr.ctrl([Qt.Key_J]) },
    function() {
      console.log("CTRL-J-IN-LIST " + (mainTab.selectedId === sr.probeId))
      sr.probeId = mainTab.selectedId; sr.ctrl([Qt.Key_K])
    },
    function() {
      console.log("CTRL-K-IN-LIST " + (mainTab.selectedId === sr.probeId))
      mainTab.pickItem(1); sr.probeId = mainTab.selectedId
      sr.ctrl([Qt.Key_C, Qt.Key_A, Qt.Key_L, Qt.Key_D, Qt.Key_N, Qt.Key_F])
    },
    function() {
      console.log("CTRL-LETTERS-IN-LIST " + (mainTab.selectedId === sr.probeId) + " " + mainTab.focusContext + " "
        + mainTab.draftNew + " " + mainTab.filterType + " " + mainTab.deleteArmed)
      keys.keyClickChar("j", Qt.NoModifier, -1)
    },
    function() {
      console.log("PLAIN-J-IN-LIST " + (mainTab.selectedId !== sr.probeId))
      sr.probeId = mainTab.itemList[0].id; mainTab.pickItem(sr.probeId); keys.keyClickChar("J", Qt.ShiftModifier, -1)
    },
    function() { console.log("SHIFT-J-IN-LIST " + (mainTab.selectedId === sr.probeId)); keys.keyClickChar("J", Qt.NoModifier, -1) },
    function() { console.log("CAPS-J-IN-LIST " + (mainTab.selectedId !== sr.probeId)); sr.click(sr.findByText(header, "History")) },
    function() {
      historyTab.moveSelection(1); sr.probeRows = historyTab.rowList.length; sr.probeId = historyTab.selectedId
      sr.ctrl([Qt.Key_J])
    },
    function() {
      console.log("CTRL-J-IN-HISTORY " + (historyTab.selectedId === sr.probeId))
      sr.probeId = historyTab.selectedId; sr.ctrl([Qt.Key_K])
    },
    function() { console.log("CTRL-K-IN-HISTORY " + (historyTab.selectedId === sr.probeId)); sr.ctrl([Qt.Key_D, Qt.Key_C]) },
    function() {
      console.log("CTRL-LETTERS-IN-HISTORY " + (historyTab.rowList.length === sr.probeRows) + " "
        + (historyTab.selectedId === sr.probeId) + " " + historyTab.deleteArmed + " " + historyTab.clearArmed)
      keys.keyClickChar("j", Qt.NoModifier, -1)
    },
    function() {
      console.log("PLAIN-J-IN-HISTORY " + (historyTab.selectedId !== sr.probeId))
      sr.probeId = historyTab.selectedId; keys.keyClickChar("J", Qt.NoModifier, -1)
    },
    function() { console.log("CAPS-J-IN-HISTORY " + (historyTab.selectedId !== sr.probeId)); sr.click(sr.findByText(header, "Items")) },

    function() { mainTab.pickItem(1); mainTab.focusEditor() },
    function() { console.log("EDITOR-TITLE-HINTS " + sr.hintKeys()); keys.keyClick(Qt.Key_Tab, Qt.NoModifier, -1) },
    function() { console.log("EDITOR-BODY-HINTS " + sr.hintKeys()); keys.keyClick(Qt.Key_Escape, Qt.NoModifier, -1) },
    function() { keys.keyClickChar("n", Qt.NoModifier, -1) },
    function() { sr.type("tomar") },
    function() { console.log("DRAFT-TYPED [" + mainTab.editorTitle + "] " + mainTab.draftType); sr.ctrl([Qt.Key_T]) },
    function() {
      console.log("DRAFT-AFTER-CTRL-T-IN-TITLE [" + mainTab.editorTitle + "] " + mainTab.draftType)
      console.log("DRAFT-TITLE-HINTS " + sr.hintKeys())
      keys.keyClick(Qt.Key_Tab, Qt.NoModifier, -1)
    },
    function() { sr.ctrl([Qt.Key_T]) },
    function() {
      console.log("DRAFT-AFTER-CTRL-T-IN-BODY [" + mainTab.editorBody + "] " + mainTab.draftType)
      console.log("DRAFT-BODY-HINTS " + sr.hintKeys())
      keys.keyClick(Qt.Key_Escape, Qt.ShiftModifier, -1)
    },

    function() { mainTab.cycleFilter() },
    function() { console.log("FILTER-AFTER-F " + mainTab.filterType + " rows=" + db.items.filter(function(i) { return i.type !== "note" }).length) },

    // qs runs under a 60 s timeout, so these three steps check what they can
    // in the same tick. An empty db._writeKind means no write was started.
    function() {
      sr.keepId = mainTab.itemList[0].id; mainTab.pickItem(sr.keepId); sr.type("dj")
      var armedAfterMove = mainTab.deleteArmed; sr.type("kd")
      console.log("ITEMS-ARMED-AFTER-MOVE " + armedAfterMove + " " + mainTab.deleteArmed)
      db.setStatus(sr.keepId, 1); db.setStatus(sr.keepId, 0)
      sr.click(sr.findByText(header, "History"))
      historyTab.selectedId = historyTab.rowList[0].id; sr.type("dj")
      armedAfterMove = historyTab.deleteArmed; sr.type("kd")
      console.log("HISTORY-ARMED-AFTER-MOVE " + armedAfterMove + " " + historyTab.deleteArmed)
      keys.keyClick(Qt.Key_Escape, Qt.NoModifier, -1)
      historyTab.selectedId = historyTab.rowList[1].id; sr.probeId = historyTab.rowList[2].id; sr.type("dd")
    },
    function() {
      console.log("ITEMS-D-AFTER-MOVING-BACK " + (sr.titleOf(sr.keepId) === "missing" ? "deleted" : "kept"))
      console.log("HISTORY-AFTER-MIDDLE-DELETE " + (historyTab.selectedId === sr.probeId ? "next-row" : "other:" + historyTab.selectedId))
      console.log("HISTORY-NOTE-LABELS " + ["read", "unread", "completed", "reopened"].map(function(label) { return !!sr.findByText(historyTab, label) }).join(" "))
      var button = sr.findType(historyTab, "ActionButton")
      sr.click(button)
      console.log("HISTORY-AFTER-ONE-CLEAR-CLICK " + (db._writeKind === "") + " " + button.text)
      // The checks after qs exits still read the log, so it is kept aside and
      // put back after c c, only if c c left the table empty.
      db._write("test", function() { return "CREATE TABLE kept_history AS SELECT * FROM history" }, null)
      sr.click(button)
      db.setStatus(sr.keepId, 1); db.setStatus(sr.keepId, 0)
      db.setStatus(3, 1); db.setStatus(3, 0)
    },
    function() {
      console.log("HISTORY-AFTER-TWO-CLEAR-CLICKS " + historyTab.rowList.length)
      console.log("HISTORY-TODO-ICONS " + !!sr.findByText(historyTab, Icons.boxOn) + " " + !!sr.findByText(historyTab, Icons.boxOff))
      sr.type("c")
      var hints = sr.findType(historyTab, "HintBar").hints.map(function(h) { return h[0] + " " + h[1] }).join(",")
      console.log("HISTORY-AFTER-ONE-C " + (db._writeKind === "") + " " + hints)
      sr.type("c")
      db._write("test", function() { return "INSERT INTO history SELECT * FROM kept_history WHERE NOT EXISTS (SELECT 1 FROM history)" }, null)

      var shown = []
      var counting = { show: function(message) { shown.push(message) } }
      mainTab.toast = counting; historyTab.toast = counting
      db.update(1, "", "")
      mainTab.toast = toast; historyTab.toast = toast
      // The failure is forced here, so it is not one of the run's write failures.
      sr.writeFailures--
      console.log("ERROR-TOASTS " + shown.filter(function(m) { return m.indexOf("Error") === 0 }).length)
    }
  ]

  function ctrl(keyList) {
    for (var i = 0; i < keyList.length; ++i) keys.keyClick(keyList[i], Qt.ControlModifier, -1)
  }
  function type(text) {
    for (var i = 0; i < text.length; ++i) keys.keyClickChar(text[i], Qt.NoModifier, -1)
  }
  function draftState() {
    return mainTab.draftNew + " [" + mainTab.editorBody + "] " + mainTab.focusContext + " toast=" + toast.text
  }
  function hintKeys() {
    return mainTab.hints.map(function(h) { return h[0] + " " + h[1] }).join(",")
  }
  function click(item) {
    keys.mouseClick(item, item.width / 2, item.height / 2, Qt.LeftButton, Qt.NoModifier, -1)
  }
  function clickSearch() { sr.click(sr.findType(mainTab, "SearchField")) }
  function firstRow(item) { return sr.findType(item, "ItemRow") }
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
      sr.mainTab = sr.findType(content, "MainTab")
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
  "SELECT title FROM items WHERE id = 2" "EDITED-RENEW"
expect "the clicked row keeps its own title" \
  "SELECT title FROM items WHERE id = 3" "Reply to upstream PR review"
logged "only the clicked row is highlighted after the save reloads the list" "HIGHLIGHTED 3$"
expect "edit is saved when focus moves to the search field" \
  "SELECT title FROM items WHERE id = 4" "EDITED-COFFEE"
logged "focus stays in the search field, and the edit is already saved before any search" "FOCUS-AFTER-SEARCH search TITLE4 EDITED-COFFEE$"
expect "committing a draft leaves the previously open item untouched" \
  "SELECT title FROM items WHERE id = 5" "Backup scratchpad.db"
expect "draft committed from the title field is saved once" \
  "SELECT COUNT(*) FROM items WHERE title = 'DRAFT-BY-ENTER'" "1"
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
logged "Esc on a draft with a body and no title keeps it open in the title field, with the warning" \
  "UNTITLED-DRAFT-AFTER-ESC true \[orphan body\] draft toast=New item needs a title$"
logged "the title hints for that draft offer Shift+Esc to discard and no longer promise save and back" \
  "UNTITLED-DRAFT-HINTS Enter/Tab to body,Shift\+Esc discard,Ctrl\+T note/todo$"
logged "Enter in the body of that draft keeps it open too" \
  "UNTITLED-DRAFT-AFTER-ENTER true \[orphan body\] draft toast=New item needs a title$"
logged "clicking a row keeps that draft open and its title focused" \
  "UNTITLED-DRAFT-AFTER-ROW-CLICK true \[orphan body\] draft toast=New item needs a title$"
logged "closing and reopening the panel shows that draft again, focused" \
  "UNTITLED-DRAFT-AFTER-REOPEN true \[orphan body\] draft"
logged "switching to History and back shows that draft again, focused" \
  "UNTITLED-DRAFT-AFTER-TAB-SWITCH true \[orphan body\] draft"
logged "New on that draft keeps it and its body, focused" \
  "UNTITLED-DRAFT-AFTER-NEW true \[orphan body\] draft"
logged "the search hints with that draft open point Enter at the draft, not the list" \
  "SEARCH-HINTS-WITH-DRAFT Enter to draft,Esc clear$"
logged "Esc in the search field returns to that draft, not to the list behind it" \
  "UNTITLED-DRAFT-AFTER-SEARCH-ESC true \[orphan body\] draft"
logged "Enter in the search field returns to that draft" \
  "UNTITLED-DRAFT-AFTER-SEARCH-ENTER true \[orphan body\] draft"
logged "Tab in the search field returns to that draft" \
  "UNTITLED-DRAFT-AFTER-SEARCH-TAB true \[orphan body\] draft"
logged "d d typed then does not delete the row hidden behind the draft" "HIDDEN-ROW-AFTER-DD kept$"
logged "Shift+Esc discards that draft and returns to the list" "UNTITLED-DRAFT-AFTER-SHIFT-ESC false list$"
expect "a draft without a title never reaches the db" \
  "SELECT COUNT(*) FROM items WHERE body = 'orphan body'" "0"
logged "Esc on an empty draft drops it without the warning" "EMPTY-DRAFT-AFTER-ESC false list toast=\[\]$"
expect "the New button commits the open draft first" \
  "SELECT COUNT(*) FROM items WHERE title = 'first draft'" "1"
logged "and then opens an empty draft" "AFTER-NEW-CLICK true \[\]$"
logged "Ctrl+J does not move the list selection" "CTRL-J-IN-LIST true$"
logged "Ctrl+K does not move the list selection" "CTRL-K-IN-LIST true$"
logged "Ctrl plus a list letter does not move, edit, delete, open a draft or filter" \
  "CTRL-LETTERS-IN-LIST true list false all false$"
expect "Ctrl+C in the list does not toggle the selected item" "SELECT status FROM items WHERE id = 1" "0"
logged "plain j still moves the list selection" "PLAIN-J-IN-LIST true$"
logged "Shift+J does not move the list selection" "SHIFT-J-IN-LIST true$"
logged "J typed with Caps Lock on moves the list selection" "CAPS-J-IN-LIST true$"
logged "Ctrl+J does not move the History selection" "CTRL-J-IN-HISTORY true$"
logged "Ctrl+K does not move the History selection" "CTRL-K-IN-HISTORY true$"
logged "Ctrl plus a History letter does not clear, move, or arm a delete or a clear" \
  "CTRL-LETTERS-IN-HISTORY true true false false$"
expect "Ctrl+C in History leaves the log in the db" "SELECT COUNT(*) > 0 FROM history" "1"
logged "plain j still moves the History selection" "PLAIN-J-IN-HISTORY true$"
logged "J typed with Caps Lock on moves the History selection" "CAPS-J-IN-HISTORY true$"
logged "the title hints of an item show Enter and Tab moving to the body" \
  "EDITOR-TITLE-HINTS Enter/Tab to body,Esc save and back,Shift\+Esc discard$"
logged "the body hints of an item show Enter and Tab saving and going back" \
  "EDITOR-BODY-HINTS Enter/Tab save and back,Shift\+Enter new line,Shift\+Tab to title,Esc save and back,Shift\+Esc discard$"
logged "a draft title starting with t keeps the t and the type" "DRAFT-TYPED \[tomar\] note$"
logged "Ctrl+T in the draft title converts it to todo and types nothing" "DRAFT-AFTER-CTRL-T-IN-TITLE \[tomar\] todo$"
logged "the draft title hints offer Ctrl+T" \
  "DRAFT-TITLE-HINTS Enter/Tab to body,Esc save and back,Shift\+Esc discard,Ctrl\+T note/todo$"
logged "Ctrl+T in the draft body converts it back to note and types nothing" "DRAFT-AFTER-CTRL-T-IN-BODY \[\] note$"
logged "the draft body hints offer Ctrl+T" \
  "DRAFT-BODY-HINTS Enter/Tab save and back,Shift\+Enter new line,Shift\+Tab to title,Esc save and back,Shift\+Esc discard,Ctrl\+T note/todo$"
logged "f cycles the type filter and the list follows" "FILTER-AFTER-F note rows=0$"
logged "moving the list selection cancels an armed delete, and d on the item again arms it" \
  "ITEMS-ARMED-AFTER-MOVE false true$"
logged "that d does not delete the item" "ITEMS-D-AFTER-MOVING-BACK kept$"
logged "moving the History selection cancels an armed delete and its red hint, and d arms again" \
  "HISTORY-ARMED-AFTER-MOVE false true$"
logged "deleting a middle History entry selects the next one" "HISTORY-AFTER-MIDDLE-DELETE next-row$"
logged "a note marked read or unread shows read and unread in History, never completed or reopened" \
  "HISTORY-NOTE-LABELS true true false false$"
logged "one click on Clear history only arms it" "HISTORY-AFTER-ONE-CLEAR-CLICK true Confirm$"
logged "a second click on Clear history clears it" "HISTORY-AFTER-TWO-CLEAR-CLICKS 4$"
logged "a completed todo shows a checked box in History, a reopened one an empty box" "HISTORY-TODO-ICONS true true$"
logged "one c only arms the clear, with its hint" "HISTORY-AFTER-ONE-C true c press again to clear$"
expect "c c clears the history" \
  "SELECT COUNT(*) FROM (SELECT id FROM history EXCEPT SELECT id FROM kept_history)" "0"
logged "a failed write shows one error toast" "ERROR-TOASTS 1$"
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
  (203, 'todo', 'Edit that fails', 'saved body', 0, $now, $now);
CREATE TRIGGER fail_add BEFORE INSERT ON items WHEN NEW.title LIKE 'FAIL-%'
  BEGIN SELECT RAISE(ABORT, 'forced failure'); END;
CREATE TRIGGER fail_edit BEFORE UPDATE OF title ON items WHEN NEW.title LIKE 'FAIL-%'
  BEGIN SELECT RAISE(ABORT, 'forced failure'); END;"
cat > "$cfg_dir/shell.qml" <<'QML'
import QtQuick
import QtTest
import Quickshell
import "data" as Data

ShellRoot {
  id: sr
  property int stepIndex: 0
  property bool started: false
  property var toasts: []
  property var mainTab: null
  property var editor: null
  readonly property var db: sr.mainTab ? sr.mainTab.db : null

  function has(text) { return sr.toasts.some(function(m) { return m.indexOf(text) >= 0 }) }
  function toastsSeen(label) {
    console.log(label + "-TOASTS [" + sr.toasts.join("|") + "]")
    return "saved=" + sr.has("Saved") + " error=" + sr.has("Error") + " added=" + sr.has("Added")
      + " removed=" + sr.has("Item removed elsewhere")
  }
  function editorState() {
    return mainTab.draftNew + " [" + mainTab.editorTitle + "] [" + mainTab.editorBody + "] dirty=" + editor.dirty
  }
  function otherId() { return mainTab.itemList[0].id === 203 ? mainTab.itemList[1].id : mainTab.itemList[0].id }

  readonly property var steps: [
    function() { mainTab.pickItem(201); mainTab.focusEditor() },
    function() { mainTab.editorTitle = "DIRTY-DELETE"; sr.toasts = []; sr.click(sr.findByText(editor, "Delete")) },
    function() { sr.click(sr.findByText(editor, "Confirm")) },
    function() { console.log("DELETE-DIRTY " + sr.toastsSeen("DELETE-DIRTY") + " deleted=" + sr.has("Deleted")) },

    function() { mainTab.pickItem(202); mainTab.focusEditor() },
    function() {
      mainTab.editorBody = "TYPED-BEFORE-REMOVAL"; sr.toasts = []
      db.fromScript(function() { return db.deleteItem(202) })
    },
    function() {
      console.log("REMOVED-ELSEWHERE " + sr.toastsSeen("REMOVED-ELSEWHERE") + " holds-removed=" + (editor.editingId === 202)
        + " " + mainTab.focusContext)
    },

    function() { mainTab.focusList(); mainTab.startNew("note") },
    function() {
      mainTab.editorTitle = "FAIL-ADD"; mainTab.editorBody = "draft body kept"; sr.toasts = []
      mainTab.commitEditor(true)
      console.log("FAILING-ADD-AT-COMMIT " + sr.toastsSeen("FAILING-ADD-AT-COMMIT"))
    },
    function() {
      console.log("FAILED-ADD " + sr.editorState() + " " + mainTab.focusContext + " " + sr.toastsSeen("FAILED-ADD"))
      mainTab.discardEditor()
    },
    function() { mainTab.startNew("todo") },
    function() {
      mainTab.editorTitle = "GOOD-ADD"; sr.toasts = []
      mainTab.commitEditor(true)
      console.log("GOOD-ADD-AT-COMMIT " + sr.toastsSeen("GOOD-ADD-AT-COMMIT"))
    },
    function() { console.log("GOOD-ADD-LATER " + sr.has("Added todo — GOOD-ADD")) },

    function() { mainTab.pickItem(203); mainTab.focusEditor() },
    function() {
      mainTab.editorTitle = "FAIL-EDIT"; mainTab.editorBody = "edit body kept"; sr.toasts = []
      mainTab.pickItem(sr.otherId())
    },
    function() {
      console.log("FAILED-EDIT-AFTER-MOVE " + (mainTab.selectedId === 203) + " " + sr.editorState() + " "
        + sr.toastsSeen("FAILED-EDIT-AFTER-MOVE"))
      mainTab.discardEditor(); mainTab.focusEditor()
    },
    function() {
      mainTab.editorTitle = "FAIL-EDIT-AGAIN"; sr.toasts = []
      mainTab.commitEditor(true)
    },
    function() {
      console.log("FAILED-EDIT-IN-PLACE " + (mainTab.selectedId === 203) + " " + sr.editorState() + " "
        + sr.toastsSeen("FAILED-EDIT-IN-PLACE"))
    }
  ]

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
      var content = null
      for (var i = 0; i < item.data.length; ++i)
        if (String(item.data[i]).indexOf("KeyboardPanel") === 0) content = item.data[i].contentItem
      var toast = sr.findType(content, "Toast")
      sr.mainTab = sr.findType(content, "MainTab")
      sr.editor = sr.findType(sr.mainTab, "EditorPane")
      sr.mainTab.toast = { show: function(message, urgent) { sr.toasts.push(String(message)); toast.show(message, urgent) } }
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

logged "deleting a dirty item with the mouse shows Deleted, never Saved or an error" \
  "DELETE-DIRTY saved=false error=false added=false removed=false deleted=true$"
expect "that edit never reaches the db" "SELECT COUNT(*) FROM history WHERE title = 'DIRTY-DELETE'" "0"
logged "an item removed by a script while being edited shows Item removed elsewhere and returns to the list" \
  "REMOVED-ELSEWHERE saved=false error=false added=false removed=true holds-removed=false list$"
expect "the text typed into the removed item is not saved anywhere" \
  "SELECT COUNT(*) FROM items WHERE body = 'TYPED-BEFORE-REMOVAL'" "0"
logged "Added does not show when a draft is committed" "FAILING-ADD-AT-COMMIT saved=false error=false added=false"
logged "a failed add puts the draft back in the editor, focused, with the error and no Added" \
  "FAILED-ADD true \[FAIL-ADD\] \[draft body kept\] dirty=false draft saved=false error=true added=false"
expect "the failed add wrote nothing" "SELECT COUNT(*) FROM items WHERE title = 'FAIL-ADD'" "0"
logged "Added waits for the database on a good add too" "GOOD-ADD-AT-COMMIT saved=false error=false added=false"
logged "Added shows once the database confirms the add" "GOOD-ADD-LATER true$"
expect "the good add is saved" "SELECT COUNT(*) FROM items WHERE title = 'GOOD-ADD'" "1"
logged "a failed edit after moving to another row reselects the item with the typed text, unsaved" \
  "FAILED-EDIT-AFTER-MOVE true false \[FAIL-EDIT\] \[edit body kept\] dirty=true saved=false error=true"
logged "a failed edit that stays on the item keeps the typed text, unsaved" \
  "FAILED-EDIT-IN-PLACE true false \[FAIL-EDIT-AGAIN\] \[saved body\] dirty=true saved=false error=true"
expect "the failed edits wrote nothing" "SELECT title || '|' || body FROM items WHERE id = 203" "Edit that fails|saved body"

echo "behavior: $checks checks, $failures failed"
exit $(( failures > 0 ))
