# Own thin controls with a fixed height

The kit's `Button` sizes itself to its content plus padding and border, so a button with an icon came out taller than one with only text. `ui/ActionButton.qml` and `ui/Field.qml` wrap the kit controls and pin them to `Style.spacing.controlHeight`. `ui/Segment.qml` is a separate control because the kit's `ButtonGroup` cannot show a count on each option.

## Consequences

- Every button and single-line field in the panel goes through these wrappers. The editor body is a plain `TextArea` that fills the remaining height and draws the kit's control fill and border, so it matches the title `Field`. `test/render.sh` fails if any control in its scenes is taller or shorter than `Style.spacing.controlHeight`.
- `Field` sets `verticalPadding: 0`, the kit's documented way to a short field, so the kit still adds the border width to the padding.
- The wrappers and the rest of the panel take colours from the kit: `Style` for fill, border, hover and selection, `PanelSeparator` for rules and `PanelSectionHeader` for the History column labels.
- Column labels are headers, not secondary text. They keep the bold `Qt.darker(foreground, 1.4)` of `PanelSectionHeader`, like the section headers of the shell's own panels (audio, bluetooth, network). On a light theme that draws them darker than the row text: on `catppuccin-latte`, `#4c4f69` becomes `#36384b`. The panel accepts that to match the rest of the shell.
- Secondary text (captions, metadata, placeholders) does not use the kit's `Color.muted` or `Qt.darker`. `Color.muted` is a fixed palette colour that ignores the bar text colour the panel draws with, and `Qt.darker` makes the dark text of a light theme stronger instead of weaker. The panel fades its foreground instead, at the two levels in `ui/Tone.js`.
- `test/tokens.test.mjs` fails on a number literal used as transparency (`Util.alpha`, `Qt.rgba`, `opacity`) and on a `Rectangle` drawn 1 px wide or tall.
