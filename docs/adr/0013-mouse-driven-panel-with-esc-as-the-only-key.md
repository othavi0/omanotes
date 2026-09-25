# A mouse-driven panel with Esc as the only key

The panel had a shortcut for every action: letters to move, edit, toggle, delete, search and filter in the list, `d d` and `c c` in History, `1` and `2` for the tabs, and `Ctrl+T` and `Shift+Esc` in the editor, with a hint bar at the bottom of both tabs to list them. The panel opens from a bar icon, so the user already has the mouse in hand, and the shortcuts cost a hint bar, a key handler per tab and a rule for each modifier. The panel is now driven by its on-screen controls, and Esc is the only key it handles: Esc closes the panel from anywhere in it, and closing commits the editor (ADR-0007). Esc with Ctrl, Alt, Super or Shift does nothing.

## Consequences

- Inside the editor only text keys remain. Tab and Enter in the title move to the body, Shift+Tab in the body moves back to the title, and Enter in the body inserts a new line. Everything else is the text field's own behaviour.
- The two actions that only had a key get a control. New opens a menu with Note and Todo, each opening a draft of that type (`newMenu` in `ui/PanelHeader.qml`). Each History entry shows a trash button while the pointer is over its row, armed like the other destructive buttons (Arm in `CONTEXT.md`).
- Choosing Note or Todo while a draft with a body and no title is open keeps that draft and gives it the chosen type, since the draft cannot be committed.
- The tabs keep a focus holder with no key handler (`focusSink`), so the kit's `KeyboardPanel.focusTarget` still has something inside the tab to give focus to, and Esc reaches `Panel.qml` from there.
- `ui/HintBar.qml` and `ui/Keycap.qml` are gone, and the Items tab gives their height to the list and the editor.
- A shortcut added later goes against this decision and needs a new ADR.
