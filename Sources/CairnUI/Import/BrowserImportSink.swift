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

    func commit(_ spaces: [SpaceCommit]) throws {
        try model.importSpaces(spaces.map { space in
            BrowserModel.SpaceImport(name: space.name, icon: space.icon, colorHex: space.colorHex, appendToExisting: space.isExisting,
                                     pins: space.pins.map { .init(title: $0.title, url: $0.url, folderPath: $0.folderPath) })
        })
    }

    func newHistoryEntries(_ entries: [ImportedHistoryEntry]) throws -> [ImportedHistoryEntry] {
        guard !entries.isEmpty else { return [] }
        guard let history else { throw ServiceError.database("History is unavailable.") }
        let fresh = Set(try history.missing(entries.map(Self.entry)).map { "\($0.url.absoluteString)\u{1E}\($0.visitedAt.timeIntervalSince1970)" })
        return entries.filter { fresh.contains("\($0.url.absoluteString)\u{1E}\($0.lastVisit.timeIntervalSince1970)") }
    }

    func recordHistory(_ entries: [ImportedHistoryEntry]) throws -> Int {
        guard let history else { throw ServiceError.database("History is unavailable.") }
        return try history.recordBatch(entries.map(Self.entry))
    }

    private static func entry(_ item: ImportedHistoryEntry) -> HistoryEntry {
        HistoryEntry(url: item.url, title: item.title, visitedAt: item.lastVisit)
    }
}
