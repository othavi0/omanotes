pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "../data/Alarm.js" as Alarm
import "Alarms.js" as Alarms
import "Icons.js" as Icons
import "Item.js" as ItemJs
import "Tone.js" as Tone

// It never touches SQL or a Db: every write goes through the alarm
// service, with the fields the editor already parsed. Like the Items tab,
// every way out of the editor except Discard commits it (ADR-0007).
FocusScope {
    id: root

    property QtObject service: null
    property var toast: null
    property color foreground: Color.foreground

    property int selectedId: -1
    property bool draftNew: false
    property int _selectAfterReload: -1

    readonly property var alarmList: root.service ? (root.service.alarms || []) : []
    readonly property int selectedIndex: ItemJs.indexOfId(root.alarmList, root.selectedId)
    readonly property var selectedAlarm: root.selectedIndex >= 0 ? root.alarmList[root.selectedIndex] : null
    readonly property double nowMs: root.service ? root.service.nowMs : 0
    readonly property bool deleteArmed: confirm.isArmedFor(root.selectedId)
    readonly property bool draftNeedsTime: root.draftNew && !editor.fields
    readonly property bool fieldFocused: editor.fieldFocused

    onFieldFocusedChanged: {
        if (editor.fieldFocused || !editor.unsaved) return
        Qt.callLater(function() { if (!editor.fieldFocused) root.commitIfDirty() })
    }

    onSelectedIdChanged: {
        confirm.cancel()
        if (root.draftNew) return
        root.saveEdit()
        root.refillEditor()
    }

    function focusList() {
        if (root.draftNew) editor.focusTime()
        else focusSink.forceActiveFocus()
    }

    function resetFocus() {
        confirm.cancel()
        if (!editor.unsaved) root.refillEditor()
        root.focusList()
    }

    function refillEditor() {
        var idx = ItemJs.indexOfId(root.alarmList, root.selectedId)
        editor.openAlarm(idx >= 0 ? root.alarmList[idx] : null)
    }

    function pickAlarm(id) {
        root._selectAfterReload = -1
        root.selectedId = Number(id)
        root.commitIfDirty()
        root.focusList()
        listView.positionViewAtIndex(root.selectedIndex, ListView.Center)
    }

    function startNew() {
        if (!root.service) return
        root.commitIfDirty()
        if (root.draftNew) { Qt.callLater(editor.focusTime); return }
        confirm.cancel()
        root.draftNew = true
        editor.openDraft()
        Qt.callLater(editor.focusTime)
    }

    function saveEdit() {
        if (!editor.dirty || !root.service) return
        var alarm = root.alarmList[ItemJs.indexOfId(root.alarmList, editor.editingId)]
        if (!alarm) return
        var timeKept = !editor.fields
        if (timeKept) {
            editor.timeText = Alarms.timeText(alarm.hour, alarm.minute)
            if (root.toast) root.toast.show("Time can't be read — kept " + editor.timeText)
        }
        var fields = editor.fields
        if (!fields) return
        editor.markSaved()
        var error = root.service.updateAlarm(alarm.id, fields)
        if (error !== "" && root.toast) root.toast.show("Error: " + error, true)
        else if (!timeKept && root.toast) root.toast.show("Saved — " + (fields.label !== "" ? fields.label : editor.timeText))
    }

    function commitEditor(returnFocus) {
        if (root.draftNeedsTime) {
            if (root.toast) root.toast.show("New alarm needs a time like 07:30")
        } else if (root.draftNew) {
            var fields = editor.fields
            root.draftNew = false
            root.refillEditor()
            var error = root.service.addAlarm(fields)
            if (error !== "" && root.toast) root.toast.show("Error: " + error, true)
        } else {
            root.saveEdit()
        }
        if (returnFocus) root.focusList()
    }

    function commitIfDirty() {
        if (root.draftNew || editor.dirty) root.commitEditor(false)
    }

    function discardEditor() {
        root.draftNew = false
        root.refillEditor()
        root.focusList()
    }

    function armDelete() {
        if (!root.service || !root.selectedAlarm) return
        if (confirm.press(root.selectedId)) {
            var alarm = root.selectedAlarm
            editor.openAlarm(null)
            var error = root.service.removeAlarm(alarm.id)
            if (error !== "") { if (root.toast) root.toast.show("Error: " + error, true); return }
            if (root.toast) root.toast.show("Deleted — " + (alarm.label !== "" ? alarm.label : editor.timeText))
            root.selectedId = ItemJs.neighbourId(root.alarmList, alarm.id)
        } else if (root.toast) {
            root.toast.show("Delete again to confirm")
        }
    }

    function toggleAlarm(id) {
        if (!root.service) return
        var error = root.service.toggleAlarm(id)
        if (error !== "" && root.toast) root.toast.show("Error: " + error, true)
    }

    function onAlarmsSynced() {
        if (root.draftNew) return
        var list = root.alarmList
        if (root._selectAfterReload >= 0 && ItemJs.indexOfId(list, root._selectAfterReload) >= 0) {
            root.selectedId = root._selectAfterReload
            root._selectAfterReload = -1
            listView.positionViewAtIndex(root.selectedIndex, ListView.Center)
        }
        var refill = !editor.fieldFocused && !editor.dirty
        if (ItemJs.indexOfId(list, root.selectedId) >= 0) {
            if (refill) root.refillEditor()
            return
        }
        root.selectedId = list.length > 0 ? list[0].id : -1
        if (refill) root.refillEditor()
    }

    onAlarmListChanged: root.onAlarmsSynced()

    Item {
        id: focusSink
        anchors.fill: parent
        focus: true
    }

    ArmedConfirm { id: confirm }

    EmptyState {
        anchors.centerIn: parent
        visible: !root.service
        creates: false
        glyph: Icons.alarm
        title: "Alarms need the Omanotes service"
        message: "Enable the plugin's service in the shell to ring alarms."
        foreground: root.foreground
    }

    RowLayout {
        anchors.fill: parent
        visible: !!root.service
        spacing: Style.spacing.xxl

        Item {
            Layout.preferredWidth: Style.space(300)
            Layout.minimumWidth: Style.space(300)
            Layout.maximumWidth: Style.space(300)
            Layout.fillHeight: true

            ListView {
                id: listView
                anchors.fill: parent
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                keyNavigationEnabled: false
                spacing: Style.spacing.xxs
                model: root.alarmList

                delegate: AlarmRow {
                    required property var modelData
                    width: listView.width
                    alarm: modelData
                    on: Alarm.isOn(modelData, root.nowMs)
                    selected: Number(modelData.id) === root.selectedId && !root.draftNew
                    nowMs: root.nowMs
                    foreground: root.foreground
                    onPicked: root.pickAlarm(modelData.id)
                    onToggled: root.toggleAlarm(modelData.id)
                }
            }

            EmptyState {
                anchors.centerIn: parent
                visible: listView.count === 0 && !root.draftNew
                creates: false
                glyph: Icons.alarm
                title: "No alarms yet"
                message: "Set a time, a label and the days it repeats."
                actionText: "Alarm"
                foreground: root.foreground
                onActionClicked: root.startNew()
            }
        }

        PanelSeparator {
            Layout.fillHeight: true
            Layout.preferredWidth: 1
            foreground: root.foreground
        }

        AlarmEditor {
            id: editor
            visible: !!root.selectedAlarm || root.draftNew
            Layout.fillWidth: true
            Layout.fillHeight: true
            alarm: root.selectedAlarm
            draft: root.draftNew
            deleteArmed: root.deleteArmed
            nowMs: root.nowMs
            foreground: root.foreground
            onEdited: if (!root.draftNew) root.commitIfDirty()
            onNewRequested: root.startNew()
            onDeleteClicked: root.armDelete()
            onSaveRequested: root.commitEditor(true)
            onDiscardRequested: root.discardEditor()
        }

        Item {
            visible: !root.selectedAlarm && !root.draftNew
            Layout.fillWidth: true
            Layout.fillHeight: true

            Text {
                anchors.centerIn: parent
                text: "Your alarm opens here."
                color: Util.alpha(root.foreground, Tone.muted)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
            }
        }
    }

    Connections {
        target: root.service
        function onAlarmAdded(id) {
            root._selectAfterReload = Number(id)
            if (root.toast) root.toast.show("Added alarm")
        }
        function onInsertFailed(record) {
            confirm.cancel()
            root.draftNew = true
            editor.reopenDraft(record)
        }
        function onFailed(message) {
            if (root.toast) root.toast.show("Error: " + String(message || "unknown"), true)
        }
    }

    Component.onCompleted: {
        root.refillEditor()
        root.focusList()
    }
}
