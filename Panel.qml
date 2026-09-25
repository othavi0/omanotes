pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "ui" as Ui
import "ui/Tabs.js" as Tabs

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
            header.closeMenu()
            itemsTab.commitIfDirty()
            return
        }
        root.db.load()
        if (root.activeTab === Tabs.items) itemsTab.resetFocus()
        else root.activeTab = Tabs.items
    }
    onActiveTabChanged: {
        itemsTab.commitIfDirty()
        if (root.activeTab === Tabs.items) itemsTab.resetFocus()
        else historyTab.resetFocus()
    }

    property int activeTab: Tabs.items

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
        focusTarget: root.activeTab === Tabs.items ? itemsTab : historyTab

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Style.space(16)
            spacing: Style.space(12)

            // Esc is the panel's only key (ADR-0013). The text fields leave it
            // unhandled, so it reaches here from anywhere in the panel.
            Keys.onPressed: function(event) {
                if (event.key !== Qt.Key_Escape || (event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) return
                root.close()
                event.accepted = true
            }

            Ui.PanelHeader {
                id: header
                Layout.fillWidth: true
                db: root.db
                activeTab: root.activeTab
                foreground: root.barForeground
                onTabPicked: function(index) { root.activeTab = index }
                onNewRequested: function(type) {
                    root.activeTab = Tabs.items
                    itemsTab.startNew(type)
                }
            }

            StackLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: root.activeTab

                Ui.ItemsTab {
                    id: itemsTab
                    db: root.db
                    toast: toast
                    foreground: root.barForeground
                }

                Ui.HistoryTab {
                    id: historyTab
                    db: root.db
                    toast: toast
                    foreground: root.barForeground
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
