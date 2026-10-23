import Foundation
import CairnCore
import CairnImport

/// Applies an import to the live browser model and history store.
@MainActor
struct BrowserImportSink: ImportSink {
    let model: BrowserModel
    let history: HistoryStore?
    var supportsFolders: Bool { true }

    func existingPinKeys(inSpaceNamed name: String) -> Set<String>? {
        model.pinnedIdentities(inSpaceNamed: name) { ImportApplier.key(folderPath: $0, url: $1) }
    }

    func existingFolderPaths(inSpaceNamed name: String) -> Set<[String]> {
        guard let folders = model.workspace.spaces.first(where: { $0.name == name })?.folders else { return [] }
        return Set(folders.map { folder in
            var path = [folder.name]
            var parent = folder.parentID
            while let id = parent, let ancestor = folders.first(where: { $0.id == id }), path.count < TabFolder.maximumDepth {
                path.insert(ancestor.name, at: 0)
                parent = ancestor.parentID
            }
            return path
        })
    }

    func commit(_ spaces: [SpaceCommit], history entries: [ImportedHistoryEntry]) throws -> Int {
        for space in spaces {
            let existing = existingPinKeys(inSpaceNamed: space.name)
            guard (existing != nil) == space.isExisting,
                  !space.pins.contains(where: { existing?.contains(ImportApplier.key(folderPath: $0.folderPath, url: $0.url)) == true }) else {
                throw ServiceError.invalidData("The destination changed since the preview. Go back and read the source again.")
            }
        }
        var added = 0
        try model.importSpaces(spaces.map { space in
            BrowserModel.SpaceImport(name: space.name, icon: space.icon, colorHex: space.colorHex, appendToExisting: space.isExisting,
                                     pins: space.pins.map { .init(title: $0.title, url: $0.url, folderPath: $0.folderPath) })
        }, beforePublishing: {
            if !entries.isEmpty {
                guard let history else { throw ServiceError.database("History is unavailable.") }
                let current = try selectHistory(entries)
                guard current.entries == entries else {
                    throw ServiceError.invalidData("History changed since the preview. Go back and read the source again.")
                }
                added = try history.recordBatch(entries.map(Self.entry))
            }
        })
        return added
    }

    func selectHistory(_ entries: [ImportedHistoryEntry]) throws -> HistorySelection {
        guard !entries.isEmpty else { return HistorySelection(entries: []) }
        guard let history else { throw ServiceError.database("History is unavailable.") }
        let existing = try history.recent(limit: history.maximumEntries)
        let keys = Set(existing.map { "\(ImportApplier.key(folderPath: [], url: $0.url))\u{1E}\($0.visitedAt.timeIntervalSince1970)" })
        let fresh = entries.filter { !keys.contains("\(ImportApplier.key(folderPath: [], url: $0.url))\u{1E}\($0.lastVisit.timeIntervalSince1970)") }
        let capacity = max(0, history.maximumEntries - existing.count)
        let selected = Array(fresh.sorted { $0.lastVisit > $1.lastVisit }.prefix(capacity))
        var skipped = SkipCounts()
        if fresh.count != entries.count { skipped[.duplicate] = entries.count - fresh.count }
        if selected.count != fresh.count { skipped[.overLimit] = fresh.count - selected.count }
        return HistorySelection(entries: selected, skipped: skipped)
    }

    private static func entry(_ item: ImportedHistoryEntry) -> HistoryEntry {
        HistoryEntry(url: item.url, title: item.title, visitedAt: item.lastVisit)
    }
}
