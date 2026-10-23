import Foundation

extension BrowserModel {
    public struct ImportedPin: Sendable {
        public var title: String
        public var url: URL
        public var folderPath: [String]
        public init(title: String, url: URL, folderPath: [String] = []) {
            self.title = title; self.url = url; self.folderPath = folderPath
        }
    }

    public struct SpaceImport: Sendable {
        public var name: String
        public var icon: String?
        public var colorHex: String?
        /// Append to the first Space with this name instead of creating one.
        public var appendToExisting: Bool
        public var pins: [ImportedPin]
        public init(name: String, icon: String? = nil, colorHex: String? = nil, appendToExisting: Bool = false, pins: [ImportedPin]) {
            self.name = name; self.icon = icon; self.colorHex = colorHex; self.appendToExisting = appendToExisting; self.pins = pins
        }
    }

    /// Adds imported pins (never live tabs) to new or existing Spaces. All-or-nothing: if the result would be
    /// invalid the workspace is left untouched and the error is thrown. New Spaces get their own storage profile.
    public func importSpaces(_ imports: [SpaceImport], beforePublishing: () throws -> Void = {}) throws {
        var draft = workspace
        var created: [UUID] = []
        for item in imports {
            var index: Int
            if item.appendToExisting, let found = draft.spaces.firstIndex(where: { $0.name == item.name }) {
                index = found
            } else {
                var space = Space(name: item.name, icon: item.icon ?? "tray.and.arrow.down", colorHex: item.colorHex ?? "#687FA0")
                if space.colorHex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) == nil { space.colorHex = "#687FA0" }
                draft.spaces.append(space)
                created.append(space.id)
                index = draft.spaces.count - 1
            }
            for pin in item.pins {
                guard URLResolver.isWebURL(pin.url) else { continue }
                var parent: UUID?
                for name in pin.folderPath {
                    var folders = draft.spaces[index].folders ?? []
                    if let existing = folders.first(where: { $0.name == name && $0.parentID == parent }) {
                        parent = existing.id
                    } else {
                        let folder = TabFolder(name: name, parentID: parent, collapsed: true)
                        folders.append(folder)
                        draft.spaces[index].folders = folders
                        parent = folder.id
                    }
                }
                var tab = TabItem(url: pin.url, title: pin.title, homeURL: pin.url)
                tab.folderID = parent
                draft.spaces[index].pinned.append(tab)
            }
        }
        try draft.validate()
        try beforePublishing()
        guard !imports.isEmpty else { return }
        workspace = draft
        if let first = created.first { selectSpace(first) } else { changed() }
    }

    /// Keys identifying a Space's pins (folder path + normalized address), used to de-duplicate re-imports.
    public func pinnedIdentities(inSpaceNamed name: String, key: (_ folderPath: [String], _ url: URL) -> String) -> Set<String>? {
        guard let space = workspace.spaces.first(where: { $0.name == name }) else { return nil }
        let folders = space.folders ?? []
        func path(of folderID: UUID?) -> [String] {
            var names: [String] = []
            var cursor = folderID
            while let id = cursor, let folder = folders.first(where: { $0.id == id }), names.count <= TabFolder.maximumDepth {
                names.insert(folder.name, at: 0)
                cursor = folder.parentID
            }
            return names
        }
        return Set((space.pinned + space.tabs).compactMap { tab in tab.url.map { key(path(of: tab.folderID), $0) } })
    }
}
