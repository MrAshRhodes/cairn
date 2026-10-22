# Link destinations

`link-rules.json` (own `schemaVersion` 1) holds a default destination for external links, an optional Peek toggle, and ordered rules `{contains | equals text → Space | most recent | quick window}`. The first matching rule wins; rules for deleted Spaces are pruned at launch. Only `http`/`https` URLs are routed (`LinkRouter`, `URLResolver.isWebURL`). A corrupt file is moved aside (`link-rules.corrupt-<time>.json`) with a visible notice; a file from a newer Cairn is left untouched and the store is read-only.

Settings ▸ Links edits the rules. Links opened from other apps (`application(_:open:)`) use them.

## Peek policy
`PeekPolicy.decide` returns `.peek` only for a cross-site link activated in a pinned tab or favorite when Peek is enabled. Same-site links navigate normally, and OAuth/payment destinations (known hosts and path hints) never become Peek. `PeekState` models open / close / expand-to-Today-tab.

## Not done (honest status)
- The Peek overlay view, the `.peekOverlay` modifier, `NavigationInterceptor`, and engine-level popup interception are not built; `PeekPolicy`/`PeekState` are tested pure logic only.
- The quick window (⌘⌥N, Open In…, auto-archive) is not built; routing to it falls back to the most recent Space.
- New-tab link opens inside the app are not routed yet; only external opens are.
- Site matching uses a small built-in two-level-suffix list, not the full public-suffix list.
