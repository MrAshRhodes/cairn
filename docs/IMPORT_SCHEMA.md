# `cairn-import-v1`

Cairn's own import format. Use it for user-authored portable data or a converter's output, then choose the file in
**File ▸ Import…**. For an ordinary bookmark HTML export, **Map an Export into Spaces…** provides a guided local mapping
flow without writing JSON; it validates the mapped result through this same schema. See the
[migration guide](features/import.md#guided-portable-workspace-migration-including-leaving-arc).
Cairn never contacts a network and never imports
passwords, cookies or extensions, whatever the file says.

```json
{
  "format": "cairn-import-v1",
  "spaces": [
    {
      "name": "Work",
      "icon": "briefcase",
      "colorHex": "#527B72",
      "pinned": [
        { "title": "Docs", "url": "https://example.com/docs", "folder": ["Team", "Reference"] },
        { "title": "Home", "url": "https://example.com/" }
      ]
    }
  ],
  "history": [
    { "url": "https://example.com/", "title": "Example", "lastVisit": 1700000000 },
    { "url": "https://example.org/", "title": "ISO form", "lastVisit": "2024-01-02T03:04:05Z" }
  ]
}
```

| Field | Rules |
|---|---|
| `format` | Optional; when present it must be `cairn-import-v1`. |
| `spaces[].name` | Required. A Space with this name is created (with its own cookie storage), or the pins are appended to an existing Space of the same name. |
| `spaces[].icon`, `colorHex` | Optional. `colorHex` must be `#RRGGBB`. |
| `pinned[].url` | `http`/`https` only. Other schemes (`javascript:`, `data:`, `file:`, `chrome:` …), credentials in the URL and addresses over 8 KiB are skipped and counted. |
| `pinned[].folder` | Optional folder names from the top. Nesting beyond 3 levels is folded into the third folder's name. |
| `history[].lastVisit` | Unix seconds (number) or an ISO-8601 string. |

Limits: 64 MiB per file, 20,000 bookmarks, 200,000 history rows, 1,024-character titles. Unknown keys are ignored.
Importing the same file twice adds nothing the second time (bookmarks match on folder path + normalized URL, history on
URL + time).
