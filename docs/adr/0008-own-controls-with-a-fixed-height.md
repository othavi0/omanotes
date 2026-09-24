# Own thin controls with a fixed height

The kit's `Button` sizes itself to its content plus padding and border, so a button with an icon came out taller than one with only text. `ui/ActionButton.qml` and `ui/Field.qml` wrap the kit controls and pin them to `Style.spacing.controlHeight`. `ui/Segment.qml` is a separate control because the kit's `ButtonGroup` cannot show a count on each option.

## Consequences

- Every button and single-line field in the panel goes through these wrappers. The editor body is a plain `TextArea` that fills the remaining height. `test/render.sh` fails if any control in its scenes is taller or shorter than `Style.spacing.controlHeight`.
