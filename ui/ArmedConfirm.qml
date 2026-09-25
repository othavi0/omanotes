import QtQuick

// Arm then confirm, for every destructive key and button in the panel. The
// first press arms a target, a second press on the same target within two
// seconds confirms it. Arming another target replaces the first.
QtObject {
    id: root

    property var target: null
    readonly property bool armed: root.target !== null

    function isArmedFor(key) {
        return root.target === key
    }

    // True when this press confirms `key`. Otherwise it arms `key`.
    function press(key) {
        if (root.isArmedFor(key)) {
            root.cancel()
            return true
        }
        root.target = key
        root.expiry.restart()
        return false
    }

    function cancel() {
        root.target = null
        root.expiry.stop()
    }

    property Timer expiry: Timer {
        interval: 2000
        onTriggered: root.target = null
    }
}
