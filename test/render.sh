#!/usr/bin/env bash
# Renders PanelHeader, ItemsTab, HistoryTab and Toast against
# a real, seeded sqlite db, offscreen, and checks that every ActionButton,
# Field, SearchField and Segment is exactly Style.spacing.controlHeight tall
# (the dev's hard rule: a button with an icon must never be taller than a
# plain text button). Some scenes also check their own layout: the toast
# wraps a long title inside the panel, History draws the kit's separators and
# section headers and shows the same EmptyState as Items, the no-match
# button names what it clears, the New menu lists Note and Todo, and an armed
# History trash reads Confirm. Exits non-zero if any check fails.
#
# Usage: test/render.sh [output-dir]
#
# Without output-dir the PNGs go to a directory removed after the run. Pass
# one to keep them for review.

set -euo pipefail

source "$(dirname "$0")/lib/harness.sh"

out_dir="${1:-$cfg_dir/shots}"
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"

cat > "$cfg_dir/shell.qml" <<'QML'
import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "data" as Data
import "ui" as Ui
import "ui/Tabs.js" as Tabs

ShellRoot {
  id: sr
  property int readyCount: 0
  property bool started: false            // guards the initial-load wait from firing again
  property int activeTab: Tabs.items
  property bool failed: false
  property string currentScene: ""
  property int sceneIndex: 0
  readonly property var scenes: Quickshell.env("SCENES").split(",")
  // A scene that finds fewer controls than this measured nothing.
  readonly property var minControls: ({ browse: 9, draft: 8, empty: 5, toast: 9, history: 3, blank: 6, historyblank: 3, menu: 11, trash: 4, drag: 9 })
  readonly property string longTitle: "Renew the domain before the card on file expires, then move the DNS records to the new registrar, check the MX entries, and write down every step so the next renewal takes five minutes instead of an afternoon"
  readonly property string outDir: Quickshell.env("OUT_DIR")

  Data.Db {
    id: db
    Component.onCompleted: db.init()
  }

  // Every scene after the first also triggers db signals (a search re-list,
  // a status/history refresh) — only the very first triple-ready should
  // kick off the scene sequence, or a later signal would race settleTimer
  // and call nextScene() again mid-sequence.
  function markReady() {
    if (sr.started) return
    sr.readyCount += 1
    if (sr.readyCount >= 3) {
      sr.started = true
      Qt.callLater(sr.nextScene)
    }
  }

  Connections {
    target: db
    function onItemsUpdated() { sr.markReady() }
    function onHistoryUpdated() { sr.markReady() }
    function onCountsUpdated() { sr.markReady() }
  }

  // Every visible item under `item` whose QML type name, parsed off its
  // toString(), matches `pattern`. A hidden item hides its subtree.
  function find(item, pattern, out) {
    out = out || []
    if (!item.visible) return out
    var n = String(item).split("_QMLTYPE")[0].split("(")[0]
    if (pattern.test(n)) out.push({ name: n, item: item })
    for (var i = 0; i < item.children.length; ++i) sr.find(item.children[i], pattern, out)
    return out
  }

  function expect(sceneName, ok, what) {
    if (!ok) sr.failed = true
    console.log("SCENE " + sceneName + " CHECK " + what + (ok ? " ok" : " FAIL"))
  }

  function checkLayout(sceneName) {
    if (sceneName === "toast") {
      var maxWidth = frame.width - 2 * Style.spacing.panelPadding
      var label = sr.find(toast, /^QQuickText$/)[0].item
      sr.expect(sceneName, toast.width <= maxWidth, "toast width " + Math.round(toast.width) + " <= " + maxWidth)
      sr.expect(sceneName, label.lineCount >= 2, "long title wraps to " + label.lineCount + " lines")
    } else if (sceneName === "empty") {
      var labels = sr.find(itemsTab, /^ActionButton$/).map(function(b) { return b.item.text })
      sr.expect(sceneName, labels.indexOf("Clear search and filter") >= 0, "buttons [" + labels.join(", ") + "] name what they clear")
    } else if (sceneName === "history") {
      sr.expect(sceneName, sr.find(historyTab, /^PanelSeparator$/).length === 2, "History uses the kit PanelSeparator")
      sr.expect(sceneName, sr.find(historyTab, /^PanelSectionHeader$/).length === 4, "History column headers are PanelSectionHeader")
    } else if (sceneName === "historyblank") {
      sr.expect(sceneName, sr.find(historyTab, /^EmptyState$/).length === 1, "empty History shows EmptyState")
    } else if (sceneName === "menu") {
      var entries = sr.find(frame, /^ActionButton$/).map(function(b) { return b.item.text })
      sr.expect(sceneName, entries.indexOf("Note") >= 0 && entries.indexOf("Todo") >= 0, "the New menu shows Note and Todo")
    } else if (sceneName === "drag") {
      var shown = function(name) { return sr.find(itemsTab, /^QQuickRectangle/).filter(function(r) { return r.item.objectName === name }).length }
      var faded = sr.find(itemsTab, /^ItemRow$/).filter(function(r) { return r.item.opacity < 1 })
      sr.expect(sceneName, shown("dragFloat") === 1 && shown("dropLine") === 1 && faded.length === 1,
        "a drag shows the floating copy, the drop line and one faded row")
    } else if (sceneName === "trash") {
      var armed = sr.find(historyTab, /^ActionButton$/).filter(function(b) { return b.item.text === "Confirm" })
      sr.expect(sceneName, armed.length === 1, "one armed trash reads Confirm")
    }
  }

  // A Popup is not an Item child, so it is looked up through `data`.
  function menuItem(obj) {
    obj = obj || header
    if (/^(QQuick)?Popup[_(]/.test(String(obj))) return obj.contentItem.parent
    var kids = obj.data || []
    for (var i = 0; i < kids.length; ++i) {
      var hit = sr.menuItem(kids[i])
      if (hit) return hit
    }
    return null
  }

  function newButton() {
    return sr.find(header, /^ActionButton$/).filter(function(b) { return b.item.text.indexOf("New") === 0 })[0].item
  }

  function checkHeights(sceneName, rootItem) {
    var found = sr.find(rootItem, /^(ActionButton|Field|SearchField|Segment)$/)
    var want = Style.spacing.controlHeight
    var parts = []
    for (var i = 0; i < found.length; ++i) {
      var row = found[i]
      var ok = row.item.height === want
      if (!ok) sr.failed = true
      parts.push(row.name + "=" + row.item.height + (ok ? "" : " MISMATCH(want " + want + ")"))
    }
    if (found.length < sr.minControls[sceneName]) {
      sr.failed = true
      parts.push("TOO-FEW-CONTROLS(" + found.length + " < " + sr.minControls[sceneName] + ")")
    }
    console.log("SCENE " + sceneName + " HEIGHTS " + parts.join(" "))
  }

  function nextScene() {
    if (sr.sceneIndex >= sr.scenes.length) {
      console.log(sr.failed ? "RESULT FAIL" : "RESULT OK")
      Qt.exit(sr.failed ? 1 : 0)
      return
    }
    var name = sr.scenes[sr.sceneIndex]
    sr.sceneIndex++
    sr.currentScene = name
    // Reset to a clean base so a scene never inherits the previous one's
    // draft, search text, or keyboard focus (an async focusTitle() queued
    // by the previous scene can otherwise still land here).
    itemsTab.draftNew = false
    itemsTab.searchText = ""
    itemsTab.focusList()
    toast.hide()
    header.closeMenu()
    sr.activeTab = (name === "history" || name === "historyblank" || name === "trash") ? Tabs.history : Tabs.items
    if (name === "draft") itemsTab.startNew("todo")
    else if (name === "empty") itemsTab.searchText = "zzz_no_match_xyz"
    else if (name === "toast") toast.show("Deleted — " + sr.longTitle)
    else if (name === "menu") sr.newButton().clicked()
    else if (name === "trash") historyTab.armDelete(Number(db.history[1].id))
    else if (name === "drag") itemsTab.dragTo(itemsTab.itemList[2], Style.space(60), itemsTab.rowStride * 0.9)
    settleTimer.restart()
  }

  Timer {
    id: settleTimer
    interval: 500
    repeat: false
    onTriggered: sr.captureScene()
  }

  function captureScene() {
    var name = sr.currentScene
    // An open popup draws in the window's overlay, outside the frame, and
    // grabToImage cannot grab the window itself. The frame starts at the
    // window's origin, so the popup keeps its place when moved under it.
    if (name === "menu") sr.menuItem().parent = frame
    sr.checkHeights(name, frame)
    sr.checkLayout(name)
    frame.grabToImage(function(r) {
      r.saveToFile(sr.outDir + "/" + name + ".png")
      itemsTab.endDrag()
      console.log("SHOT " + name + " saved")
      sr.nextScene()
    })
  }

  FloatingWindow {
    implicitWidth: 760
    implicitHeight: 520

    Rectangle {
      id: frame
      x: 0; y: 0; width: 760; height: 520
      color: Color.background

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(16)
        spacing: Style.space(12)

        Ui.PanelHeader {
          id: header
          Layout.fillWidth: true
          db: db
          activeTab: sr.activeTab
        }

        StackLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          currentIndex: sr.activeTab

          Ui.ItemsTab {
            id: itemsTab
            db: db
          }
          Ui.HistoryTab {
            id: historyTab
            db: db
          }
        }
      }

      Ui.Toast {
        id: toast
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.spacing.panelGap
        z: 10
      }
    }
  }
}
QML

echo "config dir: $cfg_dir"
if [[ -n "${1:-}" ]]; then
  echo "output dir: $out_dir"
fi
status=0
SCENES=browse,draft,empty,toast,history,menu,trash,drag OUT_DIR="$out_dir" run_qs || status=1
sqlite3 "$db" "DELETE FROM items; DELETE FROM history;"
SCENES=blank,historyblank OUT_DIR="$out_dir" run_qs || status=1
exit "$status"
