# Own thin controls with a fixed height

The kit's `Button` sizes itself to its content plus padding and border, so a button with an icon came out taller than one with only text. `ui/ActionButton.qml` and `ui/Field.qml` wrap the kit controls and pin them to `Style.spacing.controlHeight`. `ui/Segment.qml` is a separate control because the kit's `ButtonGroup` cannot show a count on each option.

## Consequences

- Every button and single-line field in the panel goes through these wrappers. The editor body is a plain `TextArea` that fills the remaining height and draws the kit's control fill and border, so it matches the title `Field`. `test/render.sh` fails if any control in its scenes is taller or shorter than `Style.spacing.controlHeight`.
- `Field` sets `verticalPadding: 0`, the kit's documented way to a short field, so the kit still adds the border width to the padding.
- The wrappers and the rest of the panel take colours from the kit: `Style` for fill, border, hover and selection, `PanelSeparator` for rules and `PanelSectionHeader` for column labels. The kit has no token for secondary text, so the two emphasis levels live in `ui/Tone.js`. `test/tokens.test.mjs` fails on a number literal passed to `Util.alpha`.
