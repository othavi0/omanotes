import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Icons.js" as Icons
import "Tabs.js" as Tabs

RowLayout {
    id: root

    property QtObject db: null
    property QtObject service: null
    property int activeTab: Tabs.items
    property color foreground: Color.foreground

    signal tabPicked(int index)
    signal newRequested(string type)

    function closeMenu() { newMenu.close() }

    spacing: Style.spacing.xxl

    Segment {
        Layout.preferredWidth: Style.space(360)
        Layout.fillWidth: false
        options: [
            { value: String(Tabs.items), label: "Items", icon: Icons.all, count: root.db ? root.db.totalNotes + root.db.totalTodos : 0 },
            { value: String(Tabs.alarms), label: "Alarms", icon: Icons.alarm, count: root.service ? root.service.onCount : 0 },
            { value: String(Tabs.history), label: "History", icon: Icons.history, count: root.db ? root.db.totalHistory : 0 }
        ]
        value: String(root.activeTab)
        foreground: root.foreground
        onPicked: function(v) { root.tabPicked(Number(v)) }
    }

    Item { Layout.fillWidth: true }

    Text {
        text: root.activeTab === Tabs.alarms && root.service ? root.service.nextSummary
            : (root.db ? root.db.unreadNotes : 0) + " unread · " + (root.db ? root.db.pendingTodos : 0) + " pending"
        color: Util.alpha(root.foreground, 0.62)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
    }

    ActionButton {
        id: newButton
        bordered: true
        selected: true
        iconText: Icons.plus
        text: "New  " + Icons.chevronDown
        foreground: root.foreground
        onClicked: newMenu.opened ? newMenu.close() : newMenu.open()
    }

    // A press on New itself does not close the menu, so the click that
    // follows can.
    QQC.Popup {
        id: newMenu
        parent: newButton
        readonly property var borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Style.normalBorderWidth)
        x: newButton.width - width
        y: newButton.height + Style.spacing.xxs
        width: Math.max(newButton.width, menuColumn.implicitWidth + leftPadding + rightPadding)
        leftPadding: Border.left(newMenu.borderSpec) + Style.spacing.xxs
        rightPadding: Border.right(newMenu.borderSpec) + Style.spacing.xxs
        topPadding: Border.top(newMenu.borderSpec) + Style.spacing.xxs
        bottomPadding: Border.bottom(newMenu.borderSpec) + Style.spacing.xxs
        closePolicy: QQC.Popup.CloseOnPressOutsideParent | QQC.Popup.CloseOnEscape

        background: BorderSurface {
            color: Color.popups.background
            borderSpec: newMenu.borderSpec
            radius: Style.cornerRadius
        }

        contentItem: ColumnLayout {
            id: menuColumn
            spacing: Style.spacing.xxs

            Repeater {
                model: [
                    { type: "note", label: "Note", icon: Icons.note },
                    { type: "todo", label: "Todo", icon: Icons.boxOff }
                ].concat(root.service ? [{ type: "alarm", label: "Alarm", icon: Icons.alarm }] : [])
                delegate: ActionButton {
                    required property var modelData
                    Layout.fillWidth: true
                    leftAlign: true
                    iconText: modelData.icon
                    text: modelData.label
                    foreground: Color.popups.text
                    onClicked: {
                        newMenu.close()
                        root.newRequested(modelData.type)
                    }
                }
            }
        }
    }
}
