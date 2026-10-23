# Boosts: visual editor, Zap, and sharing

A Boost is still CSS and optional JavaScript for matching hosts. Two additive, optional fields were added to `boosts.json` (older files load unchanged, `schemaVersion` stays 1):

- `style` (`BoostStyle`): tint colour and strength, invert lightness, contrast/brightness/saturation (0.5–1.5), font preset, text size (90–150%), text case.
- `zapped`: up to 200 selectors for elements hidden with Zap.

`BoostCSSCompiler.compile(style:zapped:)` turns these into deterministic CSS that is placed before the hand-written CSS (`Boost.effectiveCSS`). Unchanged defaults compile to nothing.

## Zap
Zap injects a hover/click picker (`ZapPickerScript`) into the active page and polls `window.__cairnZap`. Selectors come from the page, so they are limited to a tiny grammar (`ZapSelector.isSafe`): tags, `[id="x"]`, `.class`, `:nth-of-type(n)` joined with ` > `. Anything else is refused. Restore removes a selector.

## Sharing
`.cairnboost` is JSON: `{"format":"cairn-boost","schemaVersion":1,"boosts":[{name,hostPatterns,css,js,style,zapped}]}`. Import gives fresh UUIDs, accepts at most 100 Boosts and 1 MiB, and validates each. Boosts with JavaScript, `@import`, or remote `url()` import **disabled**; JavaScript additionally stays blocked until you review and allow it. CSS-only Boosts import enabled.

## Not done
The Boost popover section for the toolbar (W8 seam) is not built; no visual run of the editor UI was performed.
