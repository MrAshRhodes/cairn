# Import

**File ▸ Import…** (also *Import from Another Browser…* in the command bar) brings bookmarks and history into Cairn.
It is never automatic.

## Sources

| Source | Reads | Notes |
|---|---|---|
| Chrome, Chromium, Edge, Brave, Vivaldi, Opera, Arc's Chromium profile | `Bookmarks` and `History` of a profile folder (`Default`, `Profile 1`–`9`) | Formats are the open-source Chromium ones. Arc's own Space/pin store is **not** read (see `docs/CLEAN_ROOM.md`); use `cairn-import-v1`. |
| Firefox profile | `places.sqlite`, including committed WAL data | Select an individual profile folder. Bookmarks are on and history is off by default. See the Firefox details below. |
| Safari selected local data | `Bookmarks.plist` and, only when selected, `History.db` | No automatic Safari directory discovery or OS permission changes. See supported schemas and the HTML fallback below. |
| Bookmarks `.html` export | the chosen file | Netscape format from Safari, Firefox, Chrome and others. Scanned for tags only, never rendered. |
| `cairn-import-v1` `.json` | the chosen file | See [`../IMPORT_SCHEMA.md`](../IMPORT_SCHEMA.md). |

Never imported: passwords, cookies, `Login Data`, `Web Data`, `logins.json`, `key4.db`, form data, account credentials, local storage, extensions. Cairn does not open those files
and the file-name allow-list in the importer rejects them.

## Flow

1. **Source.** Cairn lists browsers whose folders exist (existence checks only) or you choose a file/folder.
2. **What.** Bookmarks (on) and History (off). Nothing has been read yet.
3. **Optional mapping.** **Map an Export into Spaces…** or **Guide me through mapping folders into Spaces** lets you
   name destinations and choose create/append/skip for each source folder group. Nothing is written.
4. **Preview (dry run).** Source, counts of bookmarks, new folders and history rows, what was skipped and why, and the destination.
5. **Import.** The workspace is validated before the history transaction, and published only after that transaction succeeds.
   Cancelling before this step writes no imported items. If the destination changed since preview, read the source again.
6. **Result.** A summary stays on screen.

Bookmarks become **Pinned tabs in a new Space** ("Imported from <Browser>") with its own cookies and storage; bookmark
folders become Pinned folders. Re-importing into the same Space skips what is already there. Existing data is never
changed or deleted.

## Safari: consent and permission-safe fallback

The recommended portable path is **File ▸ Import… ▸ Safari Bookmarks HTML…**. Export bookmarks using Safari's
**File ▸ Export ▸ Bookmarks** command where available. On Safari versions offering **Export Browsing Data** instead,
select bookmarks only and choose the resulting bookmarks HTML file. If Safari produces an archive, extract it yourself
and select only that HTML file; Cairn does not unpack archives or read adjacent password files. Menu labels depend on Safari
version. HTML preserves bookmark titles, web URLs and non-empty folders, **not history**, open tabs or browsing credentials.

Alternatively, **Safari Local Data…** accepts an explicitly selected directory containing `Bookmarks.plist` and optionally
`History.db`. The conventional local directory is `~/Library/Safari`; you can also choose your own authorized copy.
Cairn does not search that directory at launch or read it before **Read & Preview**. **Choose File or Folder…** also accepts
a single file named `Bookmarks.plist` (bookmarks only). Selection is not a claim that macOS permits the read.

1. Select the source yourself, review its name/path, and leave **Bookmarks** on. **History** always starts off.
2. If selecting history, confirm that reading `History.db` is intended. A missing selected file is an error, not a successful
   empty import. History-only import does not open `Bookmarks.plist`; bookmarks-only import does not open `History.db`.
3. **Read & Preview** grants consent for only that source and those data kinds.
4. If the read is denied, Cairn shows **Safari data was not imported**, explains the macOS boundary and offers
   **Use Safari HTML Export Instead…**. It does not request Full Disk Access, change file permissions, invoke privileged
   helpers or retry with another identity. Any OS grant is a separate action by the person; the import request is not a grant.
5. Review skips/destinations, then import. The default new Space is **Imported from Safari**, with its own storage profile.
   Re-import into the same destination skips identical pins and history identities.

### Supported local schemas, not a blanket version guarantee

* XML or binary `Bookmarks.plist`: a root `Children` array, `WebBookmarkTypeList` folders with `Title`/`Children`, and
  `WebBookmarkTypeLeaf` items with `URLString` and optional `URIDictionary.title`. `BookmarksBar` becomes **Favorites**;
  `BookmarksMenu` becomes **Bookmarks Menu**. Only web addresses are retained. Unsupported nodes and omitted/Reading List
  collections are counted as skipped (one per omitted node/collection); empty folders and Reading List metadata are not restored.
* `History.db`: real SQLite `history_items` (`id`, `url`) and `history_visits` (`id`, `history_item`, `title`, `visit_time`) tables.
  `visit_time` is seconds since **2001-01-01 UTC**, including fractions, never adjusted by the local timezone. Cairn retains
  the latest valid web visit per normalized URL among the newest 200,000 scanned visits; older visits, invalid dates/URLs
  and rows beyond that bound are counted. This is not a full per-visit history reconstruction.
* These shapes are independently implemented from the public [Chromium Safari bookmark importer](https://github.com/chromium/chromium/blob/main/chrome/utility/importer/safari_importer.mm)
  and [Mozilla Safari migrator](https://github.com/mozilla-firefox/firefox/blob/main/browser/components/migration/SafariProfileMigrator.sys.mjs).
  Safari's local schemas are not a stable public Apple API. Synthetic schema fixtures are verified; no specific current
  Safari/macOS account or version has been certified by those tests. Unknown schemas fail visibly. Safari cloud state,
  profiles in other private formats, tab groups, Reading List, sessions and account data remain unsupported; use an HTML
  bookmark export rather than trying to reconstruct them.

Live history uses the same bounded, read-only SQLite backup as Firefox, including committed WAL pages. The source database
and WAL are not rewritten; SQLite may coordinate through its shared-memory locking. Locked, corrupt, oversized or changing
files fail visibly; close Safari and retry with an authorized source or use the HTML fallback. Plists are bounded regular-file
reads, never executable content. The 64 MiB database/sidecar and snapshot limits, cancellation and private-staging cleanup
also apply. No Safari preferences, favicons, CloudTabs, cookies, passwords, Keychain, tokens or unrelated files are opened.

## Guided portable workspace migration (including leaving Arc)

This reconstructs a useful workspace from **data you provide**, not a direct Arc account migration. No private Arc Space/pin
database, protocol, assets or account login is used. Standard exports cannot preserve semantics they do not contain.

### Step by step

1. **Prepare a supported source.** Use a Netscape bookmarks HTML export from a browser, or a user-authored
   [`cairn-import-v1` JSON file](../IMPORT_SCHEMA.md) you have permission to use. An exported folder hierarchy inside HTML is
   supported. If you have an export directory, select the HTML/JSON file inside it, not the directory or an archive.
   Arbitrary export folders/JSON formats are not guessed or recursively scanned.
2. **Already-working Chromium route.** Arc's standard Chromium profile (`Bookmarks` and optional `History`) can still be
   selected from the source list or a folder picker, just like Chrome. This reads only that standard format, **not** Arc's
   private Space/pin store. It may contain fewer items than the Arc sidebar.
3. Open **File ▸ Import… ▸ Map an Export into Spaces…** and choose your source. Or choose a browser source, then enable
   **Guide me through mapping folders into Spaces**. Bookmarks start on; history starts off and is unavailable for HTML.
4. Confirm **Read & Preview**. Each source Space/top-level bookmark folder becomes a mapping group; unfiled bookmarks form
   their own group. Expand a group for representative titles, URLs and paths before selecting a destination.
5. Choose **Create new Space**, enter its name, or choose **Add to existing Space** and select its destination. A new name
   that already exists is rejected, not silently merged. Ambiguous duplicate existing Space names must be renamed first.
   **Do not import this group** excludes its bookmarks and reports that count.
6. Choose whether to **keep the top-level folder** inside the Space or use it only as the Space name; nested folders remain.
   Mapping multiple groups to the same name combines them into one Space. Portable JSON starts with its original Space names
   and folders; new destinations retain its icon/color, with the first group's theme used when combining groups.
7. **Preview Destinations** revalidates the conversion through `cairn-import-v1`, then uses the existing importer to show
   new/existing Spaces, pins, new folders, history and skips. Matching folders are reused; identical folder-path + normalized
   URL pins are skipped, never replaced. Existing titles/themes/storage are preserved. History remains in Cairn's local
   history store, not a Space, with capacity overflow previewed rather than evicting existing visits.
8. **Import**, or cancel without adding anything. On destination changes or an apply error, refresh the preview; do not
   assume a failed import succeeded. After importing, quit/relaunch and check your named Spaces and folders. To re-import,
   explicitly select **Add to existing Space** for those same names; duplicates are skipped.

### Expected losses and safe fallback

HTML/Chromium bookmarks do not encode Arc Space membership, pin status, themes, split views, live tabs, saved sessions,
tab groups, extensions or account state. **You supply the Space mapping; every imported bookmark becomes a pin.**
Deep folder paths fold to three levels, empty folders are omitted, and only `http`/`https` addresses without embedded
credentials are accepted. Themes can be retained only when supplied by portable JSON; they are not inferred from Arc.

If Arc offers no suitable supported export for the items you need, Cairn cannot recover that structure automatically.
Manually organize permitted URLs into folders in a browser that can export HTML (or add them directly as Cairn pins),
then use the mapping flow. Do not copy private databases, obtain account tokens, scrape private protocols, or give Cairn
passwords as a fallback. You do **not** need to write a JSON converter to map an ordinary bookmark export.

## Firefox

The source list checks only whether `~/Library/Application Support/Firefox/Profiles` exists. **Firefox — Choose Profile…**
opens a folder picker; choose the individual folder containing `places.sqlite` (often `xxxxxxxx.default-release`).
**Choose File or Folder…** also accepts profiles outside that default location. Cairn does not read `profiles.ini`, enumerate
profile contents, or open a database during discovery. Selecting a folder checks only its type and the existence of
`places.sqlite`. **Read & Preview** grants consent for that profile and the selected data kinds.

After consent, a read-only SQLite connection takes a consistent snapshot using SQLite's backup API, rather than copying
the database and WAL independently. Firefox can remain running. SQLite coordinates the read with the live database; Cairn
does not write its source database or WAL. If the database is inaccessible, busy for too long, corrupt, or has an unsupported
schema, the wizard shows the error; there is no empty-success fallback or instruction to weaken file permissions.

The parser uses Firefox's open-source Places schema:

* Bookmarks: `moz_bookmarks` folder/type/position/title/GUID relationships and the corresponding `moz_places.url`.
  Non-empty folders, Unicode titles and web URLs are retained. Toolbar, Menu, Other and Mobile roots receive stable names.
  Tags and separators are not imported; unsupported addresses and items are counted in the preview. Empty folders are not represented.
* Optional history: `moz_places.url`, `title`, `last_visit_date`, and `hidden`. As with Chromium import, this imports the
  **latest visit per URL**, not every individual visit. PRTime microseconds are converted from the Unix epoch without a
  local-timezone adjustment. Hidden rows and invalid dates are counted and skipped.
* No queries read favicons, annotations, input history, Sync metadata or other profile data. Because bookmarks and history
  share one database, the short-lived private snapshot contains the database's other pages, but those tables are not parsed.

The normal destination is **Imported from Firefox**, with its own storage profile. Re-imports into that Space skip existing
pins and history identities. History uses Cairn's existing local history store; imports use only its remaining capacity,
preview the overflow, and do not evict existing visits. The source scan is capped at 200,000 history rows and 20,000 bookmarks;
oversized/cyclic/deep folder structures fail visibly. The database plus WAL/shared-memory files and the snapshot are limited
to 64 MiB. Private staging is removed before preview is shown, including on failure or cancellation. Cleanup errors are
visible and interrupted leftovers are retried at the next launch.

References: [Mozilla Places](https://firefox-source-docs.mozilla.org/browser/places/index.html),
[open-source table definitions](https://github.com/mozilla-firefox/firefox/blob/main/toolkit/components/places/nsPlacesTables.h),
[SQLite online backup API](https://www.sqlite.org/backup.html).

## Safety

* Local only: `Sources/CairnImport` has no networking code (a test greps for it).
* Firefox and Safari databases use consistent read-only SQLite backups; Chromium History uses the existing database/WAL
  copy path. Private staging (`…/Cairn/Import/<uuid>`, mode 0700) is removed before preview, on cancellation/failure and
  at the next launch. Source databases are never opened for writing.
* Only `http`/`https` addresses are imported; everything else is skipped and counted.
* Size limits: files 64 MiB, history 200,000 rows, bookmarks 20,000.
* Workspace changes use Cairn's normal persistence. The validated workspace/history apply prevents partial changes on
  reported import errors; it is not a crash-recovery transaction spanning the workspace file and history database.

## Developing

`CairnImport` depends on `CairnCore` only. The UI (`CairnUI/Import`) implements `ImportSink` over `BrowserModel` and
`HistoryStore`. Add a source by producing `ImportedBookmark`/`ImportedHistoryEntry` values in `ImportScanner`.

Run synthetic importer coverage with `scripts/swiftw test --filter CairnImportTests`. Native service integration, including
history failure rollback, capacity preview and saved-workspace relaunch, is covered by
`scripts/swiftw test --filter BrowserImportSinkTests`. These fixtures contain no real browser profiles.
The automated suite also exercises synthetic Safari binary/XML bookmarks, live/locked WAL history, injected permission
denial with working HTML fallback, and HTML/JSON multi-Space mappings. Native service tests prove a synthetic Safari import
and a multi-Space HTML migration survive flush/shutdown/bootstrap while preserving existing data and isolated profiles.
These are **service-level relaunch tests**, not a packaged-app GUI or consenting native-account acceptance result.

Before release, exercise the actual **File ▸ Import…** sheet with synthetic Firefox/Safari data and a multi-folder portable
export: verify source pickers, defaults, explicit consent, mapping/conflicts, preview/cancel, errors, apply and saved state
after quitting/relaunching the packaged app. Safari additionally requires an **explicitly consenting macOS test account**
to check actual permission denial and the HTML fallback without escalating access. That account/GUI gate remains outstanding;
do not label a denied read or unperformed native-account check as successful import.
