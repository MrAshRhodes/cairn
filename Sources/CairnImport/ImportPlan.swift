import Foundation
import CairnCore

public struct ImportOptions: Hashable, Sendable {
    public var bookmarks: Bool
    public var history: Bool
    public init(bookmarks: Bool = true, history: Bool = false) { self.bookmarks = bookmarks; self.history = history }
}

/// The user's explicit "yes, read this" for one source. Nothing in `ImportScanner` runs without one, so create it
/// only from the confirmation step of the wizard.
public struct ImportConsent: Sendable {
    public let source: ImportSource
    public let options: ImportOptions
    public init(source: ImportSource, options: ImportOptions) { self.source = source; self.options = options }
}

public struct PlannedSpace: Sendable {
    public var name: String
    public var icon: String?
    public var colorHex: String?
    public var bookmarks: [ImportedBookmark]
}

/// What was read from the source, before comparing with what Cairn already has.
public struct ImportPlan: Sendable {
    public var sourceName: String
    public var spaces: [PlannedSpace]
    public var history: [ImportedHistoryEntry]
    public var skipped: SkipCounts
}

public struct ImportScanner: Sendable {
    private let fileSystem: ImportFileSystem
    private let staging: ImportStaging

    public init(fileSystem: ImportFileSystem = LocalImportFileSystem(), staging: ImportStaging) {
        self.fileSystem = fileSystem; self.staging = staging
    }

    /// Reads the consented source. Cancelling throws `CancellationError` and leaves nothing behind.
    public func scan(_ consent: ImportConsent) async throws -> ImportPlan {
        staging.sweep()
        let source = consent.source
        var skipped = SkipCounts()
        var spaces: [PlannedSpace] = []
        var history: [ImportedHistoryEntry] = []
        let defaultName = "Imported from \(source.browser)"
        switch source.format {
        case .chromiumProfile:
            if consent.options.bookmarks {
                let file = source.location.appendingPathComponent("Bookmarks")
                if fileSystem.exists(file) {
                    let parsed = try ChromiumBookmarks.parse(try fileSystem.read(file, maximumBytes: ImportLimits.maximumFileBytes))
                    spaces.append(PlannedSpace(name: defaultName, bookmarks: parsed.bookmarks))
                    skipped.merge(parsed.skipped, uniquingKeysWith: +)
                }
            }
            try Task.checkCancellation()
            if consent.options.history, fileSystem.exists(source.location.appendingPathComponent("History")) {
                let staged = try staging.stage(["History", "History-wal", "History-shm"], from: source.location)
                defer { staging.discard(staged) }
                try Task.checkCancellation()
                let parsed = try ChromiumHistory.read(databaseAt: staged.appendingPathComponent("History"))
                history = parsed.entries
                skipped.merge(parsed.skipped, uniquingKeysWith: +)
            }
        case .netscapeHTML:
            guard consent.options.bookmarks else { break }
            let parsed = try NetscapeHTML.parse(try fileSystem.read(source.location, maximumBytes: ImportLimits.maximumFileBytes))
            spaces.append(PlannedSpace(name: defaultName, bookmarks: parsed.bookmarks))
            skipped.merge(parsed.skipped, uniquingKeysWith: +)
        case .cairnJSON:
            let parsed = try CairnImportV1.parse(try fileSystem.read(source.location, maximumBytes: ImportLimits.maximumFileBytes))
            if consent.options.bookmarks {
                spaces = parsed.spaces.map { PlannedSpace(name: $0.name, icon: $0.icon, colorHex: $0.colorHex, bookmarks: $0.bookmarks) }
            }
            if consent.options.history { history = parsed.history }
            skipped.merge(parsed.skipped, uniquingKeysWith: +)
        }
        try Task.checkCancellation()
        return ImportPlan(sourceName: source.name, spaces: spaces, history: history, skipped: skipped)
    }
}
