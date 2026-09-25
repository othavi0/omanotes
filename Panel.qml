pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "ui" as Ui

Panel {
    id: root
    moduleName: "othavi0.omanotes"
    // BarWidget.qml owns the `scratchpad` IPC handler. manageIpc: false keeps
    // the kit Panel's own handler for this target disabled.
    ipcTarget: "scratchpad"
    manageIpc: false

    property var anchorItem: null
    property var hostWidget: null
    readonly property var barIdentity: hostWidget || root
    // The bar widget's Db, set by its injectPanel().
    property QtObject db: null

    // Reopening the panel reloads as a safety net on top of the watcher.
    // The tabs are focus scopes: the reset picks the field inside the tab
    // once, and KeyboardPanel gives the tab keyboard focus when it maps.
    onOpenedChanged: {
        if (!root.opened) {
            mainTab.commitIfDirty()
            return
        }
        root.db.load()
        if (root.activeTab === 0) mainTab.resetFocus()
        else root.activeTab = 0
    }
    onActiveTabChanged: {
        mainTab.commitIfDirty()
        if (root.activeTab === 0) mainTab.resetFocus()
        else historyTab.resetFocus()
    }

    property int activeTab: 0

    // The popup card. The kit Panel is only the state machine (open/close/
    // toggle IPC); without a popup window nothing is ever drawn, so the bar
    // button hovered but clicks only flipped `opened` invisibly. KeyboardPanel
    // binds `open` to the same controller state, so the button (and IPC) stays
    // the source of truth while the card fades in under the icon. `owner` is
    // the bar widget (not this panel) so popout coordination and the bar's
    // open-panel indicator compare against slot.activeItem correctly.
    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        owner: root.barIdentity
        bar: root.bar
        open: root.opened
        contentWidth: panel.fittedContentWidth(Style.space(760))
        contentHeight: panel.fittedContentHeight(Style.space(520))
        focusTarget: root.activeTab === 0 ? mainTab : historyTab

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Style.space(16)
            spacing: Style.space(12)

            // Keys a tab leaves unhandled bubble up here. Text fields take 1
            // and 2 as text, so only the lists switch tabs.
            Keys.onPressed: function(event) {
                if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
                if (event.text !== "1" && event.text !== "2") return
                root.activeTab = Number(event.text) - 1
                event.accepted = true
            }

            Ui.PanelHeader {
                Layout.fillWidth: true
                db: root.db
                activeTab: root.activeTab
                foreground: root.barForeground
                onTabPicked: function(index) { root.activeTab = index }
                onNewRequested: {
                    root.activeTab = 0
                    mainTab.startNew("note")
                }
            }

            StackLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: root.activeTab

                Ui.MainTab {
                    id: mainTab
                    db: root.db
                    toast: toast
                    foreground: root.barForeground
                    onCloseRequested: root.close()
                }

                Ui.HistoryTab {
                    id: historyTab
                    db: root.db
                    toast: toast
                    foreground: root.barForeground
                    onCloseRequested: root.close()
                }
            }
        }

        // Transient confirmation line (delete/status/save feedback).
        Ui.Toast {
            id: toast
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.spacing.panelGap
            z: 10
        }
    }
}
