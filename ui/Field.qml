import QtQuick
import qs.Commons
import qs.Ui

// Single-line text field pinned to Style.spacing.controlHeight and
// vertically centered. The kit's TextField pads for a taller default;
// verticalPadding: 0 drops that padding and keeps the border the kit adds.
TextField {
    implicitHeight: Style.spacing.controlHeight
    verticalPadding: 0
    verticalAlignment: TextInput.AlignVCenter
}
