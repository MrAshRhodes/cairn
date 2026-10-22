import Foundation
import CairnCore

public struct SpaceCommit: Sendable {
    public var name: String
    public var icon: String?
    public var colorHex: String?
    /// True when a Space with this name already exists and the pins are appended to it.
    public var isExisting: Bool
    public var pins: [ImportedBookmark]
    public var folderCount: Int
}

/// Cairn's side of an import. `CairnUI` implements it over `BrowserModel` and `HistoryStore`; tests use fakes.
@MainActor
public protocol ImportSink {
    var supportsFolders: Bool { get }
    /// Keys (see `ImportApplier.key`) of pins already in the Space called `name`, or nil if there is no such Space.
    func existingPinKeys(inSpaceNamed name: String) -> Set<String>?
    /// Adds all Spaces and pins atomically: either everything is added or nothing is.
    func commit(_ spaces: [SpaceCommit]) throws
    /// Entries not already in history.
    func newHistoryEntries(_ entries: [ImportedHistoryEntry]) throws -> [ImportedHistoryEntry]
    /// Adds the entries in one transaction and returns how many were stored.
    func recordHistory(_ entries: [ImportedHistoryEntry]) throws -> Int
}

/// The dry run: exactly what `ImportApplier.apply` will add.
public struct ImportPreview: Sendable {
    public var spaces: [SpaceCommit]
    public var history: [ImportedHistoryEntry]
    public var skipped: SkipCounts
    public var bookmarkCount: Int { spaces.reduce(0) { $0 + $1.pins.count } }
    public var folderCount: Int { spaces.reduce(0) { $0 + $1.folderCount } }
    public var historyCount: Int { history.count }
    public var isEmpty: Bool { bookmarkCount == 0 && history.isEmpty }
}

public struct ImportResult: Equatable, Sendable {
    public var spacesTouched: Int
    public var bookmarksAdded: Int
    public var foldersAdded: Int
    public var historyAdded: Int
    public var skipped: SkipCounts
}

public enum ImportApplier {
    public static func key(folderPath: [String], url: URL) -> String {
        folderPath.joined(separator: "\u{1F}") + "\u{1E}" + Sanitizer.key(url)
    }

    /// Compares the plan with what Cairn already has. Pure apart from the read-only sink queries.
    @MainActor
    public static func preview(_ plan: ImportPlan, sink: ImportSink) throws -> ImportPreview {
        var skipped = plan.skipped
        var commits: [SpaceCommit] = []
        for planned in plan.spaces {
            let existing = sink.existingPinKeys(inSpaceNamed: planned.name)
            var seen = existing ?? []
            var pins: [ImportedBookmark] = []
            var folders = Set<[String]>()
            for var bookmark in planned.bookmarks {
                bookmark.folderPath = Array(bookmark.folderPath.prefix(TabFolder.maximumDepth - 1))
                    + (bookmark.folderPath.count >= TabFolder.maximumDepth
                        ? [bookmark.folderPath.dropFirst(TabFolder.maximumDepth - 1).joined(separator: " / ")] : [])
                guard seen.insert(key(folderPath: bookmark.folderPath, url: bookmark.url)).inserted else {
                    skipped[.duplicate, default: 0] += 1
                    continue
                }
                if sink.supportsFolders {
                    for depth in bookmark.folderPath.indices { folders.insert(Array(bookmark.folderPath.prefix(depth + 1))) }
                } else if !bookmark.folderPath.isEmpty {
                    bookmark.title = (bookmark.folderPath + [bookmark.title]).joined(separator: " / ")
                    bookmark.folderPath = []
                }
                pins.append(bookmark)
            }
            if !pins.isEmpty || existing == nil {
                commits.append(SpaceCommit(name: planned.name, icon: planned.icon, colorHex: planned.colorHex,
                                           isExisting: existing != nil, pins: pins, folderCount: folders.count))
            }
        }
        let newHistory = try sink.newHistoryEntries(plan.history)
        skipped[.duplicate, default: 0] += plan.history.count - newHistory.count
        if skipped[.duplicate] == 0 { skipped[.duplicate] = nil }
        return ImportPreview(spaces: commits, history: newHistory, skipped: skipped)
    }

    /// Applies a preview. Cancellation is honoured before anything is changed; after that the commit is atomic.
    @MainActor
    public static func apply(_ preview: ImportPreview, to sink: ImportSink,
                             isCancelled: () -> Bool = { Task.isCancelled }) throws -> ImportResult {
        if isCancelled() { throw CancellationError() }
        try sink.commit(preview.spaces)
        let added = preview.history.isEmpty ? 0 : try sink.recordHistory(preview.history)
        return ImportResult(spacesTouched: preview.spaces.count, bookmarksAdded: preview.bookmarkCount,
                            foldersAdded: preview.folderCount, historyAdded: added, skipped: preview.skipped)
    }
}
