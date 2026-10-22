# Command bar

The command bar is one surface with three entry points. Each has a different Enter behavior.

| Shortcut | Mode | Enter on a typed address or search |
| --- | --- | --- |
| ⌘K | Search everything | Opens the result in a **new tab** |
| ⌘T | New tab | Opens the result in a **new tab** |
| ⌘L | Navigate | Loads the result in the **current tab**. The field is prefilled with the current address and the typed address is selected by default |

## Results

Results appear in this order, after a direct address or site-search row (when the text is one):

1. Open tabs and Space tabs, then pinned tabs and favorites. Matches at the start of a word rank higher.
2. Up to 8 history entries that are not already open tabs, deduplicated by URL.
3. Commands, including module commands and actions that take a Space ("Move to…", "Pin to…").
4. A "search the web" fallback. It is the first row when the text is a direct address, otherwise the last.

Prefix the query with `>` to list commands only. Arrow keys move the selection; Esc closes the bar.

## Site search

A site-search keyword searches one site directly. Type the keyword, press Tab, then type the query.
The site shows as a chip; Delete on an empty field removes it. Typing `keyword query` and pressing Enter works too.

Manage keywords in **Settings → Site Search**. A keyword is 1–16 letters, digits, `-` or `_`. The URL must be
`http(s)` with exactly one `%s`, which is replaced by the percent-encoded query. One keyword can be made the default
engine for plain searches; otherwise the engine from General settings is used.

Keywords are stored in `site-search.json` in the application data folder. An unreadable file is moved to
`site-search.json.corrupt-<time>`, a notice explains what happened, and editing starts from an empty list.
