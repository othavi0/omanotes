#!/usr/bin/env bash
# Renders PanelHeader, ItemsTab, AlarmsTab, HistoryTab, SettingsTab, RingCard and Toast
# against a real, seeded sqlite db, offscreen, and checks that every
# ActionButton, Field, SearchField, Segment and Stepper is exactly
# Style.spacing.controlHeight tall (the dev's hard rule: a button with an
# icon must never be taller than a plain text button). TimeField is the one
# control outside that rule (ADR-0008). Some scenes also check their own
# layout: the toast wraps a long title inside the panel, History draws the
# kit's separators and section headers and shows the same EmptyState as
# Items, the no-match button names what it clears, the New menu lists Note,
# Todo and Alarm, an armed trash or Delete reads Confirm, the day chips run
# Monday first, the tab Segment has four options with an icon-only gear, the
# ring card names Snooze and Stop, and each Settings page fits the panel. Exits non-zero if any check fails.
#
# Usage: test/render.sh [output-dir]
#
# Without output-dir the PNGs go to a directory removed after the run. Pass
# one to keep them for review.

set -euo pipefail
export TZ=America/Sao_Paulo

source "$(dirname "$0")/lib/harness.sh"

out_dir="${1:-$cfg_dir/shots}"
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"

# The alarms, seen at 14:02 today and armed at midnight, so
# no earlier occurrence is owed. The service's clock is off and every scene
# ticks NOW_MS. The player and the notification are stubbed away.
day="$(date +%F)"
ms() { echo $(( $(date -d "$1" +%s) * 1000 )); }
now_ms="$(ms "$day 14:02")"
midnight="$(ms "$day 00:00")"
sqlite3 "$db" "INSERT INTO alarms (id, hour, minute, label, days, enabled, snoozed_until_ms, armed_at_ms) VALUES
  (1, 7, 30, 'Wake up', 65, 1, 0, $midnight),
  (2, 16, 30, 'Stand-up', 62, 1, 0, $midnight),
  (3, 22, 0, 'Take the pills', 127, 1, $(ms "$day 14:11"), $midnight),
  (4, 6, 15, 'Early flight', 0, 0, 0, $midnight);"
mkdir "$cfg_dir/bin"
for stub in pw-play omarchy-notification-send; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$cfg_dir/bin/$stub"
  chmod +x "$cfg_dir/bin/$stub"
done

cat > "$cfg_dir/shell.qml" <<'QML'
import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "data" as Data
import "ui" as Ui
import "ui/Tabs.js" as Tabs
import "ui/Icons.js" as Icons
import "ui/Settings.js" as Settings

ShellRoot {
  id: sr
  property int readyCount: 0
  property bool started: false            // guards the initial-load wait from firing again
  property int activeTab: Tabs.items
  property bool failed: false
  property string currentScene: ""
  property int sceneIndex: 0
  readonly property var scenes: Quickshell.env("SCENES").split(",")
  readonly property real nowMs: Number(Quickshell.env("NOW_MS"))
  // A scene that finds fewer controls than this measured nothing.
  readonly property var minControls: ({ browse: 9, draft: 8, empty: 5, toast: 9, history: 3, blank: 6, historyblank: 3, menu: 12, trash: 4, drag: 9,
    alarms: 14, alarmdraft: 14, alarmconfirm: 14, alarmblank: 3, ringcard: 11,
    settings: 11, settingsalarms: 8, settingshistory: 3 })
  readonly property string longTitle: "Renew the domain before the card on file expires, then move the DNS records to the new registrar, check the MX entries, and write down every step so the next renewal takes five minutes instead of an afternoon"
  readonly property string outDir: Quickshell.env("OUT_DIR")

  Data.ItemsDb {
    id: db
    Component.onCompleted: db.init()
  }

  // The alarm service, with its clock off and no ring window: the card is
  // rendered inside the frame instead.
  Component {
    id: noWindow
    QtObject { required property var modelData }
  }
  Loader {
    id: svc
    Component.onCompleted: setSource("file://" + Quickshell.env("OMANOTES_WORKTREE") + "/Service.qml",
      { clockRunning: false, screens: [], ringWindow: noWindow })
  }
  Connections {
    target: svc.item
    function onLoadedChanged() { if (svc.item.loaded) sr.markReady() }
  }

  // Every scene after the first also triggers db signals (a search re-list,
  // a status/history refresh) — only the very first ready of every read and
  // of the service should kick off the scene sequence, or a later signal
  // would race settleTimer and call nextScene() again mid-sequence.
  function markReady() {
    if (sr.started) return
    sr.readyCount += 1
    if (sr.readyCount >= 4) {
      sr.started = true
      svc.item.tick(sr.nowMs)
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
      sr.expect(sceneName, entries.indexOf("Note") >= 0 && entries.indexOf("Todo") >= 0 && entries.indexOf("Alarm") >= 0,
        "the New menu shows Note, Todo and Alarm")
    } else if (sceneName === "alarms" || sceneName === "alarmdraft" || sceneName === "alarmconfirm") {
      var chips = sr.find(alarmsTab, /^ActionButton$/).filter(function(b) { return b.item.objectName === "dayChip" }).map(function(b) { return b.item.text })
      sr.expect(sceneName, chips.join(" ") === "M T W T F S S", "the day chips read [" + chips.join(" ") + "]")
      sr.checkTabs(sceneName)
      var timeField = sr.find(alarmsTab, /^TimeField$/)
      sr.expect(sceneName, timeField.length === 1 && timeField[0].item.height === timeField[0].item.implicitHeight, "one TimeField takes the height its digits need")
      if (sceneName === "alarms") {
        var texts = sr.find(alarmsTab, /^QQuickText$/).map(function(t) { return t.item.text })
        sr.expect(sceneName, texts.indexOf("weekends · next Sat") >= 0 && texts.indexOf("every day · snoozed to 14:11") >= 0 && texts.indexOf("once · off") >= 0,
          "the rows read the days and the state")
        var summary = sr.find(header, /^QQuickText$/).map(function(t) { return t.item.text })
        sr.expect(sceneName, summary.indexOf("next alarm 14:11") >= 0, "the header names the next alarm [" + summary.join("|") + "]")
      } else if (sceneName === "alarmconfirm") {
        var armed = sr.find(alarmsTab, /^ActionButton$/).filter(function(b) { return b.item.text === "Confirm" })
        sr.expect(sceneName, armed.length === 1, "an armed Delete reads Confirm")
      }
    } else if (sceneName === "alarmblank") {
      var blank = sr.find(alarmsTab, /^EmptyState$/)
      var action = sr.find(alarmsTab, /^ActionButton$/).map(function(b) { return b.item.text })
      sr.expect(sceneName, blank.length === 1 && action.indexOf("Alarm") >= 0, "empty Alarms shows EmptyState with + Alarm")
    } else if (sceneName === "ringcard") {
      var cardButtons = sr.find(ringCard, /^ActionButton$/).map(function(b) { return b.item.text })
      sr.expect(sceneName, cardButtons.join("|") === "Snooze 9 min|Stop", "the ring card offers [" + cardButtons.join("|") + "]")
      var cardTexts = sr.find(ringCard, /^QQuickText$/).map(function(t) { return t.item.text })
      sr.expect(sceneName, cardTexts.indexOf("14:03") >= 0 && cardTexts.indexOf("Wake up") >= 0, "the ring card shows the clock and the title")
    } else if (sceneName === "drag") {
      var shown = function(name) { return sr.find(itemsTab, /^QQuickRectangle/).filter(function(r) { return r.item.objectName === name }).length }
      var faded = sr.find(itemsTab, /^ItemRow$/).filter(function(r) { return r.item.opacity < 1 })
      sr.expect(sceneName, shown("dragFloat") === 1 && shown("dropLine") === 1 && faded.length === 1,
        "a drag shows the floating copy, the drop line and one faded row")
    } else if (sceneName.indexOf("settings") === 0) {
      sr.checkTabs(sceneName)
      var page = sr.find(settingsTab, /StackLayout$/)[0].item
      var rows = sr.find(settingsTab, /^SettingRow$/)
      sr.expect(sceneName, rows.length > 0 && rows.every(function(r) { return r.item.width <= page.width + 0.5 }),
        rows.length + " setting rows fit the page (" + rows.map(function(r) { return Math.round(r.item.width) }).join(",") + " <= " + Math.round(page.width) + ")")
      var overflow = sr.find(settingsTab, /^(ActionButton|Segment|Stepper|PanelSlider)$/).filter(function(c) {
        var right = c.item.mapToItem(settingsTab, c.item.width, 0).x
        return right > settingsTab.width + 0.5
      })
      sr.expect(sceneName, overflow.length === 0, "no control reaches past the tab (" + overflow.map(function(c) { return c.name }).join(",") + ")")
      var sections = sr.find(settingsTab, /^QQuickRectangle/).filter(function(r) { return String(r.item.objectName).indexOf("section:") === 0 })
      sr.expect(sceneName, sections.length === Settings.SECTIONS.length, "the list shows " + sections.length + " sections")
      var texts = sr.find(settingsTab, /^QQuickText$/).map(function(t) { return t.item.text })
      if (sceneName === "settings") {
        var sounds = sr.find(settingsTab, /^(QQuickRectangle|SoundRow)/).filter(function(r) { return String(r.item.objectName).indexOf("sound:") === 0 })
        sr.expect(sceneName, sounds.length === 7, "the page lists six sounds and the custom file (" + sounds.length + ")")
        var stops = sr.find(settingsTab, /^(ActionButton|PlayButton)$/).filter(function(b) { return b.item.iconText === Icons.stop })
        sr.expect(sceneName, stops.length === 2, "the sound being tested and Test both show stop (" + stops.length + ")")
        sr.expect(sceneName, texts.indexOf("Alarm clock") >= 0 && texts.indexOf("Custom file…") >= 0 && texts.indexOf("100%") >= 0,
          "the page names the sounds and the volume")
      } else if (sceneName === "settingshistory") {
        var keep = sr.find(settingsTab, /^Segment$/).filter(function(c) { return c.item.objectName === "keep" })
        sr.expect(sceneName, keep.length === 1 && keep[0].item.value === "0" && texts.indexOf("forever") >= 0,
          "History keeps entries forever by default")
      } else if (sceneName === "settingsalarms") {
        sr.expect(sceneName, texts.indexOf("9 min") >= 0 && texts.indexOf("5 min") >= 0 && texts.indexOf("9 / 5 min") >= 0,
          "the steppers and the Alarms row read the defaults")
      }
    } else if (sceneName === "trash") {
      var armed = sr.find(historyTab, /^ActionButton$/).filter(function(b) { return b.item.text === "Confirm" })
      sr.expect(sceneName, armed.length === 1, "one armed trash reads Confirm")
    }
  }

  function checkTabs(sceneName) {
    var segment = sr.find(header, /^Segment$/)[0].item
    var chips = sr.find(segment, /^QQuickRectangle/).filter(function(r) { return r.item.parent === segment })
    var gear = chips[3] ? chips[3].item : null
    sr.expect(sceneName, segment.options.length === 4 && segment.options[3].label === "" && !!gear && gear.width < chips[2].item.width,
      "the tab Segment has four options, the last an icon-only gear narrower than History (" + (gear ? gear.width : "-") + ")")
    sr.expect(sceneName, header.implicitWidth <= frame.width - 2 * Style.space(16), "the header fits the panel (" + header.implicitWidth + ")")
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
    var found = sr.find(rootItem, /^(ActionButton|PlayButton|Field|MinutesField|SearchField|Segment|Stepper)$/)
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
    alarmsTab.discardEditor()
    toast.hide()
    header.closeMenu()
    svc.item.stopPreview()
    sr.activeTab = (name === "history" || name === "historyblank" || name === "trash") ? Tabs.history
      : name.indexOf("alarm") === 0 ? Tabs.alarms : name.indexOf("settings") === 0 ? Tabs.settings : Tabs.items
    if (name === "draft") itemsTab.startNew("todo")
    else if (name === "empty") itemsTab.searchText = "zzz_no_match_xyz"
    else if (name === "toast") toast.show("Deleted — " + sr.longTitle)
    else if (name === "menu") sr.newButton().clicked()
    else if (name === "trash") historyTab.armDelete(Number(db.history[1].id))
    else if (name === "drag") itemsTab.dragTo(itemsTab.itemList[2], Style.space(60), itemsTab.rowStride * 0.9)
    else if (name === "alarms") alarmsTab.pickAlarm(1)
    else if (name === "alarmdraft") alarmsTab.startNew()
    else if (name === "alarmconfirm") { alarmsTab.pickAlarm(1); alarmsTab.armDelete() }
    else if (name === "ringcard") svc.item.tick(sr.nowMs + 60000)
    else if (name === "settings") { settingsTab.pickSection("sound"); svc.item.previewKey = "alarm-clock-elapsed" }
    else if (name === "settingsalarms") settingsTab.pickSection("alarms")
    else if (name === "settingshistory") settingsTab.pickSection("history")
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
          service: svc.item
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
          Ui.AlarmsTab {
            id: alarmsTab
            service: svc.item
          }
          Ui.HistoryTab {
            id: historyTab
            db: db
          }
          Ui.SettingsTab {
            id: settingsTab
            db: db
            service: svc.item
          }
        }
      }

      Ui.RingCard {
        id: ringCard
        visible: sr.currentScene === "ringcard"
        service: svc.item
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: Style.space(10)
        z: 20
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
export OMANOTES_WORKTREE="$worktree" NOW_MS="$now_ms" PATH="$cfg_dir/bin:$PATH"
SCENES=browse,draft,empty,toast,history,menu,trash,drag,alarms,alarmdraft,alarmconfirm,settings,settingsalarms,settingshistory OUT_DIR="$out_dir" run_qs || status=1
# A one-shot due one minute after NOW_MS rings in its own run, so the other
# scenes never see it.
sqlite3 "$db" "INSERT INTO alarms (id, hour, minute, label, days, enabled, armed_at_ms) VALUES (5, 14, 3, 'Wake up', 0, 1, $midnight)"
SCENES=ringcard OUT_DIR="$out_dir" run_qs || status=1
sqlite3 "$db" "DELETE FROM items; DELETE FROM history; DELETE FROM alarms;"
SCENES=blank,historyblank,alarmblank OUT_DIR="$out_dir" run_qs || status=1
exit "$status"
