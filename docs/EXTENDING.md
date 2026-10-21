# Extend Cairn locally

This guide is for people adding their own commands or per-site styles, and contributors wiring those features into the app. You can add a JSON command module or a CSS Boost without an account, service, native plug-in, or telemetry.

Cairn has three extension points:

| Extension | What it does | How it is installed |
| --- | --- | --- |
| Built-in module | Contributes native browser commands | Compiled with the open-source app |
| User module | Opens an HTTP(S) URL or runs explicitly trusted, local JavaScript on command | Local JSON file |
| Boost | Applies CSS and optionally explicitly trusted, local JavaScript to matching sites | Local `boosts.json` managed by `BoostStore` |

There is no downloaded plug-in manager, arbitrary Swift compilation, executable launcher, or dynamic-library loader. Loading JSON validates data; it does not open URLs or run scripts. These are original Cairn extension contracts, not an implementation of another browser's plug-in format.

## Add a command module

Place a UTF-8 `.json` file in `~/Library/Application Support/Cairn/Modules/`. The host app loads this directory at startup or when its reload action calls `loadUserModules(from:)`. There is no automatic file watcher.

Start with this URL-only module:

```json
{
  "schemaVersion": 1,
  "id": "local.reading",
  "name": "Reading",
  "version": "1.0.0",
  "commands": [
    {
      "id": "open-example",
      "title": "Open Example",
      "subtitle": "Open a reference page",
      "symbol": "book",
      "keywords": ["reading", "reference"],
      "action": {
        "type": "openURL",
        "url": "https://example.com/",
        "target": "newTab"
      }
    }
  ]
}
```

The command ID becomes `local.reading.open-example`. The `target` is `newTab` by default, or `currentTab` to navigate the selected tab. When there is no selected tab, either target creates one. Only absolute HTTP(S) URLs without embedded credentials or whitespace are accepted; `javascript:`, `file:`, `data:`, shell commands and native code are not actions.

`subtitle`, `symbol`, `keywords`, and `shortcut` are optional. Symbols use macOS SF Symbol names. A shortcut is a display hint, not a new system-wide or application key binding.

Validation rules:

- `schemaVersion` must be `1`; name, version and command titles must be nonempty.
- IDs use ASCII letters, numbers, dots, underscores and hyphens, up to 128 bytes. Module IDs starting with `cairn.` are reserved, case-insensitively.
- Display strings are limited to 512 UTF-8 bytes without control characters. Each command may have up to 32 keywords.
- Each module has 1–100 commands; a directory has at most 128 JSON files, each at most 1 MiB.
- Unknown fields, unsupported actions, duplicate IDs, invalid JSON and symbolic-link module files are errors.
- Non-JSON files and hidden files are ignored; subdirectories are not searched.

Files are processed in filename order. The loader validates the entire directory before replacing previously loaded user modules. A failed reload keeps the previous working modules, returns an error identifying the file, and calls the registry's error handler. A successful reload removes deleted modules, activates replacements if the registry is active, and revokes their old JavaScript grants. A missing directory is an empty module set.

### Optional JavaScript command

A local command can instead declare:

```json
{
  "id": "highlight-headings",
  "title": "Highlight Headings",
  "action": {
    "type": "javaScript",
    "source": "document.querySelectorAll('h1, h2').forEach(el => { el.style.outline = '2px solid currentColor'; });"
  }
}
```

**This code is disabled until the user explicitly trusts that command.** A JSON field cannot grant trust. The host must show the exact loaded source from `javaScriptSource(for: commandID)` and a warning before calling `setJavaScriptTrusted(true, for: commandID)`. Running an untrusted command reports an error rather than silently executing. JavaScript source must be nonempty and at most 256 KiB.

**Trusted JavaScript runs unsandboxed in the selected page's context. It can read site data available to the page, modify content, make requests, and perform actions as the signed-in user.** Use only code you authored locally and understand. Never trust downloaded or pasted code merely because it appears in a JSON file. Trust is not a guarantee that the code is safe.

These commands run only when invoked, on the selected HTTP(S) page, not automatically on navigation. Both the browser state and the executing document's protocol are checked. Grants are in memory only and are revoked when the module is reloaded, deactivated or removed, or the application restarts. Engine evaluation errors are delivered to `ModuleRegistry.onError`.

## Add per-site styles with Boosts

`BoostStore(directory:)` owns a `boosts.json` file in its supplied local directory. The conventional app location is `~/Library/Application Support/Cairn/Boosts/`. A minimal document is:

```json
{
  "schemaVersion": 1,
  "boosts": [
    {
      "id": "a0176480-2d1a-4cea-9702-499c4ca4b101",
      "name": "Readable Example",
      "hostPatterns": ["example.com"],
      "css": "body { font-family: system-ui, sans-serif; line-height: 1.65; }",
      "js": "",
      "isEnabled": true
    }
  ]
}
```

Prefer the throwing `add`, `update`, `remove` and `setEnabled` APIs instead of editing a file while the app is running. Each successful mutation writes the full validated document atomically before publishing the changed array. An I/O or validation failure throws without publishing a partial mutation. A newly constructed store loads existing data before its first mutation, so it does not accidentally replace an existing file with an empty list.

`load()` rejects corrupted JSON, unknown schema versions, duplicate UUIDs, invalid patterns, symbolic links, and oversized files. It does not replace in-memory Boosts or overwrite invalid files on failure. Surface errors to the user; do not catch them with `try?` and pretend the operation succeeded. Back up an invalid file before repairing it. Keep one store per directory: this is not a multi-process database or a file-merging service.

A Boost needs a nonempty name, 1–100 patterns, and CSS/JavaScript of at most 256 KiB each. A store accepts up to 1,000 Boosts and an encoded document of at most 8 MiB. Empty CSS and JavaScript are allowed as an editor draft.

### Host matching

| Pattern | Matches | Does not match |
| --- | --- | --- |
| `example.com` | `example.com`, `www.example.com`, `a.b.example.com` | `evilexample.com`, `example.com.evil.test` |
| `*.example.com` | Subdomains such as `www.example.com` | Bare `example.com` |
| `*` | Every HTTP(S) host, explicitly | `file:`, `about:`, `data:`, other schemes |

Patterns contain hosts, not URLs, ports, paths, credentials, regular expressions, or partial globs. ASCII DNS names (including punycode), `localhost` and IPv4 literals are accepted. Hostnames are case-insensitive and one trailing DNS dot is normalized. Specific IPv6 patterns are not supported; `*` also includes HTTP(S) IPv6 hosts. Use a narrow hostname instead of `*` whenever possible.

CSS is assigned to a style element's `textContent` using a JSON-encoded JavaScript string literal. Quotes, backslashes, line breaks, template expressions and closing script-tag text cannot escape it and become JavaScript. Reapplying the same Boost updates its existing style element instead of adding duplicates.

**CSS is not a privacy sandbox.** Authored styles can hide important controls or load external resources through `url()` and `@import`. The examples use neither external resources nor JavaScript. Cairn adds no telemetry.

### Boost JavaScript and updates

The JSON `js` field is **off by default**, even when `isEnabled` is true. Only a separate explicit call to `setJavaScriptTrusted(true, for: boostID)` permits it after source review and the same unsandboxed-site-data warning as module JavaScript.

Trust is session-only, not serialized. Reloading the store or changing JavaScript or host patterns revokes that Boost's grant. Disabling a Boost prevents both CSS and JavaScript injection on subsequent documents. Re-enabling an unchanged Boost preserves an existing session grant. CSS remains available without granting JavaScript trust.

After edits, removals, enable toggles, or trust changes, call `BrowserModel.refreshUserScripts()`. The engine replaces future-document scripts; **reload an already loaded page** to see styles removed or changed. Revoking trust cannot undo JavaScript that has already executed. Runtime errors in automatically injected Boost JavaScript are handled by the engine/page console, not the storage API.

`scripts(for:)` intentionally returns **all enabled guarded scripts**, regardless of the passed URL (including `nil` and `about:blank`). The engine retains scripts while a tab navigates between sites. Each script checks the actual document's protocol and hostname before doing anything. Filtering scripts solely by the tab's initial URL would miss later sites and is not supported.

## Wire the extension points into an app

All registry and store operations run on the main actor:

```swift
let registry = ModuleRegistry()
registry.onError = { error in
    // Present the error through the application's existing error UI.
    showError(error.localizedDescription)
}
for module in BuiltinModules.all() {
    try registry.registerValidated(module)
}
try registry.loadUserModules(from: modulesDirectory)
registry.activate(model: model)

let boosts = BoostStore(directory: boostsDirectory)
try boosts.load()
model.userScriptProvider = { [weak boosts] url in
    boosts?.scripts(for: url) ?? []
}
model.refreshUserScripts()
```

Here `model` is the host's `BrowserModel`; `modulesDirectory` and `boostsDirectory` are local directory URLs; `showError` stands for the host's own error presentation. Retain the registry and store for the app/window lifetime. Show load failures instead of aborting browser startup.

Use `registry.allCommands(for: model)` to populate a command menu and invoke `command.perform(model)` only on user selection. It automatically activates the registry for that model. Native registration is first-wins: `registerValidated` throws on duplicate module IDs, while the nonthrowing `register` reports the error through `lastError`/`onError`. Duplicate command IDs are surfaced and the later command is omitted. `unregister` deactivates the removed module; call `deactivate` when the owning session shuts down.

The built-ins cover new/duplicate/close tabs, pin/unpin, favorite/unfavorite, resetting a pinned URL, manual archive/restore, next/previous tab, split view, spaces, back/forward, stop, reload/cache-bypassing reload and bounded page zoom. Commands are offered according to the current model state. Archiving the last ordinary tab opens a blank replacement; closing pinned/favorite tabs follows the model's unload-without-removal behavior.

Contributors can implement `CairnModule` in the application source and register the compiled instance. Keep activation/deactivation balanced, release observers in `deactivate()`, use stable unique IDs, and route changes through `BrowserModel` methods. User JSON modules cannot install these native implementations.

## Examples and verification

The repository's `examples/modules` directory includes a URL-only command module. `examples/boosts` includes a ready-to-load CSS-only `boosts.json` for `example.com`. Copy the module into your Modules directory; import the example Boost through `BoostStore.add`, or use its document in a new empty Boosts directory. Do not replace an existing Boosts document without a backup.

Run `scripts/swiftw test --filter CairnModulesTests` for focused validation, or `scripts/swiftw test` for all targets. The tests use a fake browser engine, project-local isolated storage fixtures and JavaScriptCore to verify runtime host guards, safe CSS encoding, disabled-by-default JavaScript, lifecycle, strict module loading, command execution and persistence failures.
