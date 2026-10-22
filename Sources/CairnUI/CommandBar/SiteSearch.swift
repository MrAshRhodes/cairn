import Foundation
import CairnCore

/// A keyword that expands to a search on one site, e.g. `w swift` → a Wikipedia search.
public struct SiteSearchEngine: Codable, Equatable, Identifiable, Sendable {
    public var keyword: String
    public var name: String
    /// HTTP(S) URL with exactly one `%s` placeholder in the query string.
    public var template: String
    public var id: String { keyword }

    public init(keyword: String, name: String, template: String) {
        self.keyword = keyword; self.name = name; self.template = template
    }

    public static func isValidKeyword(_ keyword: String) -> Bool {
        (1...16).contains(keyword.count) && keyword.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    public var isValid: Bool {
        Self.isValidKeyword(keyword) && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && URLResolver.isValidSearchTemplate(template)
    }

    /// The expanded URL, or nil when the template is not a safe search template.
    public func url(for query: String) -> URL? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, URLResolver.isValidSearchTemplate(template),
              let encoded = text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }
}

public struct SiteSearchQuery: Equatable, Sendable {
    public let engine: SiteSearchEngine
    public let query: String
}

public enum SiteSearch {
    /// `keyword query` or `keyword⇥query`. Keywords match case-insensitively; the query must not be empty.
    public static func parse(_ input: String, engines: [SiteSearchEngine]) -> SiteSearchQuery? {
        let text = input.drop { $0.isWhitespace }
        guard let split = text.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
        let keyword = String(text[..<split])
        let query = text[split...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let engine = engines.first(where: { $0.keyword.caseInsensitiveCompare(keyword) == .orderedSame })
        else { return nil }
        return SiteSearchQuery(engine: engine, query: query)
    }

    /// The engine whose keyword is the whole input (optionally followed by spaces); Tab turns it into a search chip.
    public static func keyword(_ input: String, engines: [SiteSearchEngine]) -> SiteSearchEngine? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return engines.first { $0.keyword.caseInsensitiveCompare(text) == .orderedSame }
    }
}

/// Site-search keywords in `site-search.json`. Unreadable files are moved aside, never overwritten.
@MainActor @Observable
public final class SiteSearchStore {
    nonisolated public static let currentSchemaVersion = 1
    nonisolated public static let maximumEngines = 100
    public private(set) var engines: [SiteSearchEngine] = []
    /// Keyword of the engine that replaces the Settings search engine for plain queries; nil keeps Settings.
    public private(set) var defaultKeyword: String?
    public private(set) var isWritable = true
    @ObservationIgnored public let fileURL: URL
    @ObservationIgnored public var onError: ((String, String) -> Void)?

    private struct Document: Codable {
        var schemaVersion = SiteSearchStore.currentSchemaVersion
        var defaultKeyword: String?
        var engines: [SiteSearchEngine]
    }

    public init(directory: URL) { fileURL = directory.appendingPathComponent("site-search.json") }

    public var defaultEngine: SiteSearchEngine? { defaultKeyword.flatMap { key in engines.first { $0.keyword == key } } }

    public func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 1_000_000 else {
                throw ServiceError.invalidData("Expected a regular file smaller than 1 MB.")
            }
            let data = try Data(contentsOf: fileURL)
            struct Header: Decodable { let schemaVersion: Int }
            let version = try JSONDecoder().decode(Header.self, from: data).schemaVersion
            guard version == Self.currentSchemaVersion else { throw ServiceError.unsupportedSchema(version) }
            let document = try JSONDecoder().decode(Document.self, from: data)
            try Self.validate(document.engines, defaultKeyword: document.defaultKeyword)
            engines = document.engines
            defaultKeyword = document.defaultKeyword
        } catch {
            let moved = quarantine()
            isWritable = moved != nil
            onError?("Site search keywords could not be read",
                     "\(error.localizedDescription)\n" + (moved.map { "The file was moved to \($0.lastPathComponent) and keywords start empty." }
                        ?? "The original file is preserved. Changes will not be saved this session."))
        }
    }

    public func add(_ engine: SiteSearchEngine) throws {
        var updated = engines.filter { $0.keyword.caseInsensitiveCompare(engine.keyword) != .orderedSame }
        updated.append(engine)
        try apply(updated, defaultKeyword: defaultKeyword)
    }

    public func remove(keyword: String) throws {
        try apply(engines.filter { $0.keyword != keyword }, defaultKeyword: defaultKeyword == keyword ? nil : defaultKeyword)
    }

    public func setDefault(keyword: String?) throws { try apply(engines, defaultKeyword: keyword) }

    private func apply(_ updated: [SiteSearchEngine], defaultKeyword newDefault: String?) throws {
        guard isWritable else { throw ServiceError.invalidData("Site search is read-only because its saved file could not be set aside.") }
        try Self.validate(updated, defaultKeyword: newDefault)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(Document(defaultKeyword: newDefault, engines: updated)).write(to: fileURL, options: .atomic)
        engines = updated
        defaultKeyword = newDefault
    }

    private static func validate(_ engines: [SiteSearchEngine], defaultKeyword: String?) throws {
        guard engines.count <= maximumEngines else { throw ServiceError.invalidData("Too many site-search keywords.") }
        guard engines.allSatisfy(\.isValid) else {
            throw ServiceError.invalidData("A keyword is 1–16 letters, digits, - or _, and its URL must be http(s) with exactly one %s in the query.")
        }
        guard Set(engines.map { $0.keyword.lowercased() }).count == engines.count else {
            throw ServiceError.invalidData("Keywords must be unique.")
        }
        if let defaultKeyword, !engines.contains(where: { $0.keyword == defaultKeyword }) {
            throw ServiceError.invalidData("The default search keyword does not exist.")
        }
    }

    private func quarantine() -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        var target = fileURL.deletingLastPathComponent().appendingPathComponent("site-search.json.corrupt-\(stamp)")
        var counter = 1
        while FileManager.default.fileExists(atPath: target.path) {
            target = fileURL.deletingLastPathComponent().appendingPathComponent("site-search.json.corrupt-\(stamp)-\(counter)")
            counter += 1
        }
        do { try FileManager.default.moveItem(at: fileURL, to: target); return target } catch { return nil }
    }
}
