import Foundation

/// Persists the keymap preset and user remaps in `shortcuts.json`. Unreadable files are moved aside, never overwritten.
@MainActor
public final class ShortcutStore {
    nonisolated public static let currentSchemaVersion = 1
    public let fileURL: URL

    private struct Document: Codable {
        var schemaVersion = ShortcutStore.currentSchemaVersion
        var preset: KeymapPreset
        var bindings: [String: KeyChord]
        var cleared: [String]
    }

    public struct Loaded {
        public var map: ShortcutMap
        public var quarantinedTo: URL?
        public var error: Error?
    }

    public init(directory: URL) { fileURL = directory.appendingPathComponent("shortcuts.json") }

    public func load(base: ShortcutMap = ShortcutMap()) -> Loaded {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Loaded(map: base) }
        do {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 1_000_000 else {
                throw ShortcutError(message: "The shortcuts file is not a regular file or is too large.")
            }
            let data = try Data(contentsOf: fileURL)
            struct Header: Decodable { let schemaVersion: Int }
            let version = try JSONDecoder().decode(Header.self, from: data).schemaVersion
            guard version == Self.currentSchemaVersion else { throw ShortcutError(message: "Unsupported shortcuts file version \(version).") }
            let document = try JSONDecoder().decode(Document.self, from: data)
            var map = ShortcutMap(actions: base.actions, preset: document.preset,
                                  assigned: document.bindings, cleared: Set(document.cleared))
            // New defaults must not steal saved remaps. System keys still win; duplicate custom
            // bindings in a hand-edited file are resolved in catalog order.
            var seen = Set(map.actions.filter { !$0.remappable }.compactMap { map.chord(for: $0.id) })
            for action in map.actions where action.remappable && map.assigned[action.id] != nil {
                guard let chord = map.chord(for: action.id), !seen.insert(chord).inserted else { continue }
                map.reset(action.id)
            }
            for action in map.actions where action.remappable && map.assigned[action.id] == nil {
                guard let chord = map.chord(for: action.id), !seen.insert(chord).inserted else { continue }
                try? map.assign(nil, to: action.id)
            }
            return Loaded(map: map)
        } catch {
            return Loaded(map: base, quarantinedTo: quarantine(), error: error)
        }
    }

    public func save(_ map: ShortcutMap) throws {
        let document = Document(preset: map.preset, bindings: map.assigned, cleared: map.cleared.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(document).write(to: fileURL, options: .atomic)
    }

    private func quarantine() -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        var target = fileURL.deletingLastPathComponent().appendingPathComponent("shortcuts.json.corrupt-\(stamp)")
        var counter = 1
        while FileManager.default.fileExists(atPath: target.path) {
            target = fileURL.deletingLastPathComponent().appendingPathComponent("shortcuts.json.corrupt-\(stamp)-\(counter)")
            counter += 1
        }
        do { try FileManager.default.moveItem(at: fileURL, to: target); return target } catch { return nil }
    }
}
