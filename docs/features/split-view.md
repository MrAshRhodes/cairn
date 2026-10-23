# Split view

A Space can show up to **four** tabs at once, arranged by a tree of horizontal and vertical splits.

## Using it

- **⇧⌘D** toggles split view. With no split it pairs the current tab with another tab of the Space (or a new one).
- Add a pane on the right, left, top or bottom with the Split View menu or command bar ("Split: Add Pane on…"). The
  tab context menu has "Open Alongside Current Tab".
- Drag a divider to resize. Panes keep at least 240 pt.
- Click a pane (or press ⌃⇧1–4 with the Arc preset, or set your own) to focus it. The focused pane is the selected tab,
  so ⌘L, ⌘W and the toolbar act on it.
- The ✕ in a pane header takes that tab out of the split; the tab itself is kept. A split with one pane left dissolves.
  "Separate All Panes" dissolves the whole split.

A tab belongs to at most one split. Closing, archiving or moving a tab to another Space removes it from its split.

## Persistence

Layouts are stored in `splits.json` (separately from the session so older builds keep working). Invalid panes are repaired
away on launch. An unreadable file is moved to `splits.json.corrupt-<time>` and a notice is shown.

## Limits

Panes are rendered as a flat list positioned from the layout tree, so a layout change moves views rather than recreating
them. This has been exercised in unit tests only; it has not yet been verified with the bundled Chromium engine in a
running app.
