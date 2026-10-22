# Keyboard shortcuts

Menus, the command bar and the shortcuts pane are built from one action registry, so a menu item, its shortcut
and its command-bar row always agree. Open **Help → Cairn Keyboard Shortcuts** (or run "Keyboard Shortcuts" in the
command bar) to view and change them.

## Presets

Choose **Cairn** or **Arc-compatible** in the pane. The Arc preset maps Arc's table where Cairn has the feature:
⌘S sidebar, ⌘D pin or unpin, ⇧⌘K clear today's tabs, ⌃⇧+ / ⌃⇧− add or remove a split pane, ⌃⇧1–4 focus a pane.
Switching presets resets custom shortcuts.

## Defaults

| Area | Shortcut |
| --- | --- |
| New tab / command bar / address | ⌘T / ⌘K / ⌘L |
| Close tab / close window | ⌘W / ⇧⌘W |
| Reopen closed tab | ⇧⌘T (last 25 tabs; Clear Today restores as one batch) |
| Copy page address / as Markdown link | ⇧⌘C / ⌥⇧⌘C |
| Find, next, previous | ⌘F, ⌘G, ⇧⌘G |
| Sidebar | ⇧⌘S |
| Reload, hard reload, stop | ⌘R, ⇧⌘R, ⌘. |
| Back / forward | ⌘[ / ⌘] |
| Next / previous tab | ⌥⌘↓ / ⌥⌘↑ |
| Tab 1–8, last tab | ⌘1–⌘8, ⌘9 |
| Recent tabs (hold ⌃, release to switch) | ⌃⇥ / ⌃⇧⇥ |
| Space 1–9 | ⌃1–⌃9 |
| Next / previous Space | ⌥⌘→ / ⌥⌘← |
| Toggle split view | ⇧⌘D |
| History, Downloads, Settings | ⌘Y, ⌘J, ⌘, |

## Changing shortcuts

Click a shortcut, press the new keys, or press Esc to cancel. A shortcut needs ⌘, ⌃ or ⌥ so typing is never affected.
A shortcut already in use is refused, with a message naming the action that owns it; change or clear that one first.
System shortcuts (Quit, Hide, Cut, Copy, Paste, Undo…) are fixed and reserve their keys. Module commands that declare
a shortcut appear under Tools; if it collides with a bound key it is left unassigned rather than taking it.

Changes are saved to `shortcuts.json`. An unreadable file is moved to `shortcuts.json.corrupt-<time>`, the default
keymap is used, and a notice is shown.

## Arc shortcuts Cairn does not implement

- ⌘N New window, ⇧⌘N Incognito window, ⌥⌘N Little Arc window: Cairn has a single window and no incognito mode.
- ⌘← / ⌘→ for history: this conflicts with text editing. Use ⌘[ and ⌘].
