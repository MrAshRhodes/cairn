# Import

**File ▸ Import…** (also *Import from Another Browser…* in the command bar) brings bookmarks and history into Cairn.
It is never automatic.

## Sources

| Source | Reads | Notes |
|---|---|---|
| Chrome, Chromium, Edge, Brave, Vivaldi, Opera, Arc's Chromium profile | `Bookmarks` and `History` of a profile folder (`Default`, `Profile 1`–`9`) | Formats are the open-source Chromium ones. Arc's own Space/pin store is **not** read (see `docs/CLEAN_ROOM.md`); use `cairn-import-v1`. |
| Bookmarks `.html` export | the chosen file | Netscape format from Safari, Firefox, Chrome and others. Scanned for tags only, never rendered. |
| `cairn-import-v1` `.json` | the chosen file | See [`../IMPORT_SCHEMA.md`](../IMPORT_SCHEMA.md). |

Never imported: passwords, cookies, `Login Data`, `Web Data`, local storage, extensions. Cairn does not open those files
and the file-name allow-list in the importer rejects them.

## Flow

1. **Source.** Cairn lists browsers whose folders exist (existence checks only) or you choose a file/folder.
2. **What.** Bookmarks (on) and History (off). Nothing has been read yet.
3. **Preview (dry run).** Counts of bookmarks, folders and history rows, what was skipped and why, and the destination.
4. **Import.** Applied atomically; cancelling before this step leaves no trace.
5. **Result.** A summary stays on screen.

Bookmarks become **Pinned tabs in a new Space** ("Imported from <Browser>") with its own cookies and storage; bookmark
folders become Pinned folders. Re-importing into the same Space skips what is already there. Existing data is never
changed or deleted.

## Safety

* Local only: `Sources/CairnImport` has no networking code (a test greps for it).
* The History database is copied (with its `-wal`) into a private scratch folder (`…/Cairn/Import/<uuid>`, mode 0700),
  opened read-only, and the folder is removed on completion, cancel, and at next launch.
* Only `http`/`https` addresses are imported; everything else is skipped and counted.
* Size limits: files 64 MiB, history 200,000 rows, bookmarks 20,000.

## Developing

`CairnImport` depends on `CairnCore` only. The UI (`CairnUI/Import`) implements `ImportSink` over `BrowserModel` and
`HistoryStore`. Add a source by producing `ImportedBookmark`/`ImportedHistoryEntry` values in `ImportScanner`.
