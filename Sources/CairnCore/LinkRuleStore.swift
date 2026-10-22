import Foundation

/// `link-rules.json`: the default destination for external links plus ordered rules. It has its own schema version.
public final class LinkRuleStore {
    public static let schemaVersion = 1
    public static let maximumRules = 200

    struct Document: Codable {
        var schemaVersion: Int
        var defaultDestination: LinkDestination
        var peekEnabled: Bool?
        var rules: [LinkRule]
    }

    public let url: URL
    public private(set) var rules: [LinkRule] = []
    public private(set) var defaultDestination: LinkDestination = .mostRecent
    public var peekEnabled = true
    /// Set when the file could not be used; the original is preserved and edits are refused.
    public private(set) var loadError: String?
    /// Informational: a corrupt file was moved aside and defaults are in use (edits still allowed).
    public private(set) var notice: String?
    public var isWritable: Bool { loadError == nil }

    public init(url: URL) { self.url = url }

    public func load() {
        loadError = nil; notice = nil
        let data: Data?
        do { data = try JSONStorage.read(url) } catch {
            loadError = error.localizedDescription
            return
        }
        guard let data else { return }
        do {
            let document = try JSONStorage.decode(Document.self, from: data, schema: Self.schemaVersion)
            guard document.rules.count <= Self.maximumRules else { throw ServiceError.limit("Too many link rules.") }
            rules = document.rules; defaultDestination = document.defaultDestination; peekEnabled = document.peekEnabled ?? true
        } catch ServiceError.unsupportedSchema(let version) {
            loadError = "link-rules.json was written by a newer Cairn (schema \(version)). It has not been changed."
        } catch {
            // Corrupt: keep the evidence next to the original and start from defaults.
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = url.deletingLastPathComponent().appendingPathComponent("link-rules.corrupt-\(stamp).json")
            do {
                try FileManager.default.moveItem(at: url, to: aside)
                notice = "link-rules.json was unreadable and was moved to \(aside.lastPathComponent). Defaults are in use."
            } catch {
                loadError = "link-rules.json is unreadable and could not be moved aside. It has not been changed."
            }
        }
    }

    public func update(rules: [LinkRule], defaultDestination: LinkDestination, peekEnabled: Bool) throws {
        guard isWritable else { throw ServiceError.invalidData(loadError ?? "Link rules are read-only.") }
        guard rules.count <= Self.maximumRules, rules.allSatisfy({ $0.text.count <= 512 }) else {
            throw ServiceError.limit("Link rules are limited to \(Self.maximumRules) rules of at most 512 characters.")
        }
        try JSONStorage.write(Document(schemaVersion: Self.schemaVersion, defaultDestination: defaultDestination,
                                       peekEnabled: peekEnabled, rules: rules), to: url)
        self.rules = rules; self.defaultDestination = defaultDestination; self.peekEnabled = peekEnabled
    }

    public func prune(validSpaceIDs: Set<UUID>) throws {
        let result = LinkRouter.pruned(rules: rules, default: defaultDestination, spaceIDs: validSpaceIDs)
        guard result.rules != rules || result.default != defaultDestination, isWritable else { return }
        try update(rules: result.rules, defaultDestination: result.default, peekEnabled: peekEnabled)
    }

    public func destination(for url: URL) -> LinkDestination? {
        LinkRouter.destination(for: url, rules: rules, default: defaultDestination)
    }
}
