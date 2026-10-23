import Foundation

public struct MigrationGroup: Identifiable, Sendable {
    public let id: Int
    public let sourceSpace: String
    public let topLevelFolder: String?
    public let bookmarks: [ImportedBookmark]
    public let icon: String?
    public let colorHex: String?
    public var label: String { topLevelFolder.map { "\(sourceSpace) / \($0)" } ?? "\(sourceSpace) / Unfiled pins" }
}

public enum MigrationConflict: String, CaseIterable, Sendable {
    case create = "Create new Space"
    case append = "Add to existing Space"
    case skip = "Do not import this group"
}

public struct MigrationMapping: Identifiable, Sendable {
    public let id: Int
    public var destinationName: String
    public var conflict: MigrationConflict
    public var keepTopLevelFolder: Bool

    public init(group: MigrationGroup, preserveSourceSpace: Bool = false) {
        id = group.id
        destinationName = preserveSourceSpace ? group.sourceSpace : (group.topLevelFolder ?? group.sourceSpace)
        conflict = .create
        keepTopLevelFolder = preserveSourceSpace
    }
}

/// A local, user-directed conversion into the existing portable schema, not a new apply path.
public enum ImportMigration {
    public static let limitations = "HTML and standard Chromium exports carry bookmarks and folders, not Arc Spaces or pin status. You choose the Spaces; every imported bookmark becomes a pin. Empty folders, tab groups, live tabs, split views, saved sessions and account data cannot be restored. Deep folders are folded to three levels. No private Arc data is read."

    public static func groups(in plan: ImportPlan) -> [MigrationGroup] {
        var groups: [MigrationGroup] = []
        for space in plan.spaces {
            var paths: [String?] = []
            var bookmarks: [String?: [ImportedBookmark]] = [:]
            for bookmark in space.bookmarks {
                let path = bookmark.folderPath.first
                if bookmarks[path] == nil { paths.append(path) }
                bookmarks[path, default: []].append(bookmark)
            }
            for path in paths {
                groups.append(MigrationGroup(id: groups.count, sourceSpace: space.name, topLevelFolder: path,
                                             bookmarks: bookmarks[path] ?? [], icon: space.icon, colorHex: space.colorHex))
            }
        }
        return groups
    }

    public static func plan(from original: ImportPlan, mappings: [MigrationMapping], existingSpaceNames: [String],
                            isCancelled: () -> Bool = { Task.isCancelled }) throws -> ImportPlan {
        if isCancelled() { throw CancellationError() }
        let groups = groups(in: original)
        guard mappings.count == groups.count, Set(mappings.map(\.id)) == Set(groups.map(\.id)) else {
            throw ImportError.malformed("Map each source group exactly once.")
        }
        let choices = Dictionary(uniqueKeysWithValues: mappings.map { ($0.id, $0) })
        var spaces: [[String: Any]] = []
        var destinations: [String: Int] = [:]
        var policies: [String: MigrationConflict] = [:]
        var skipped = original.skipped
        for group in groups {
            if isCancelled() { throw CancellationError() }
            guard let mapping = choices[group.id] else { continue }
            if mapping.conflict == .skip {
                skipped[.userExcluded, default: 0] += group.bookmarks.count
                continue
            }
            let name = mapping.destinationName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 256, Sanitizer.title(name) == name else {
                throw ImportError.malformed("Use a non-empty Space name of at most 256 characters without control characters.")
            }
            let matches = existingSpaceNames.filter { $0 == name }.count
            switch mapping.conflict {
            case .create:
                guard matches == 0 else {
                    throw ImportError.malformed("“\(name)” already exists. Choose Add to existing Space or a different name.")
                }
            case .append:
                guard matches == 1 else {
                    throw ImportError.malformed("Choose exactly one existing Space named “\(name)”. Rename ambiguous Spaces before importing.")
                }
            case .skip: break
            }
            if let policy = policies[name], policy != mapping.conflict {
                throw ImportError.malformed("Groups mapped to “\(name)” must use the same destination policy.")
            }
            policies[name] = mapping.conflict
            let index: Int
            if let existing = destinations[name] {
                index = existing
            } else {
                index = spaces.count
                destinations[name] = index
                var space: [String: Any] = ["name": name, "pinned": [[String: Any]]()]
                if let icon = group.icon { space["icon"] = icon }
                if let color = group.colorHex { space["colorHex"] = color }
                spaces.append(space)
            }
            var pins = spaces[index]["pinned"] as? [[String: Any]] ?? []
            for bookmark in group.bookmarks {
                if isCancelled() { throw CancellationError() }
                let path = mapping.keepTopLevelFolder || group.topLevelFolder == nil
                    ? bookmark.folderPath : Array(bookmark.folderPath.dropFirst())
                pins.append(["title": bookmark.title, "url": bookmark.url.absoluteString, "folder": path])
            }
            spaces[index]["pinned"] = pins
        }
        let history: [[String: Any]] = original.history.map {
            ["url": $0.url.absoluteString, "title": $0.title, "lastVisit": $0.lastVisit.timeIntervalSince1970]
        }
        let data = try JSONSerialization.data(withJSONObject: ["format": CairnImportV1.formatName, "spaces": spaces, "history": history])
        if isCancelled() { throw CancellationError() }
        let validated = try CairnImportV1.parse(data)
        skipped.merge(validated.skipped, uniquingKeysWith: +)
        return ImportPlan(sourceName: original.sourceName,
                          spaces: validated.spaces.map { PlannedSpace(name: $0.name, icon: $0.icon, colorHex: $0.colorHex, bookmarks: $0.bookmarks) },
                          history: validated.history, skipped: skipped)
    }
}
