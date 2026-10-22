import Foundation

/// `.cairnboost` sharing format: a versioned JSON document of Boosts, imported as fresh, reviewable copies.
public enum BoostExchange {
    public static let format = "cairn-boost"
    public static let schemaVersion = 1
    public static let maximumBoosts = 100
    public static let maximumBytes = 1_048_576

    struct Document: Codable {
        var format: String
        var schemaVersion: Int
        var boosts: [Entry]
    }

    struct Entry: Codable {
        var name: String
        var hostPatterns: [String]
        var css: String
        var js: String
        var style: BoostStyle?
        var zapped: [String]?
    }

    public struct ImportResult: Sendable {
        public var boosts: [Boost]
        /// IDs of imported Boosts that were disabled because they carry JavaScript or load remote resources.
        public var needsReview: Set<UUID>
    }

    public static func export(_ boosts: [Boost]) throws -> Data {
        let document = Document(format: format, schemaVersion: schemaVersion, boosts: boosts.map {
            Entry(name: $0.name, hostPatterns: $0.hostPatterns, css: $0.css, js: $0.js, style: $0.style, zapped: $0.zapped)
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    public static func importBoosts(from data: Data) throws -> ImportResult {
        guard data.count <= maximumBytes else { throw BoostError.invalid("A .cairnboost file is limited to 1 MiB.") }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) } catch {
            throw BoostError.invalid("This is not a valid .cairnboost file.")
        }
        guard document.format == format else { throw BoostError.invalid("This is not a Cairn Boost file.") }
        guard document.schemaVersion <= schemaVersion else {
            throw BoostError.invalid("This Boost file was made by a newer version of Cairn.")
        }
        guard document.boosts.count <= maximumBoosts else {
            throw BoostError.invalid("A .cairnboost file may contain at most \(maximumBoosts) Boosts.")
        }
        var result = ImportResult(boosts: [], needsReview: [])
        for entry in document.boosts {
            let risky = !entry.js.isEmpty || referencesRemoteResources(entry.css)
            let boost = Boost(name: entry.name, hostPatterns: entry.hostPatterns, css: entry.css, js: entry.js,
                              isEnabled: !risky, style: entry.style, zapped: entry.zapped)
            try boost.validate()
            result.boosts.append(boost)
            if risky { result.needsReview.insert(boost.id) }
        }
        return result
    }

    /// Remote `url()` and `@import` can leak browsing to a third party, so shared CSS that uses them needs review.
    static func referencesRemoteResources(_ css: String) -> Bool {
        let lowered = css.lowercased()
        if lowered.contains("@import") { return true }
        return lowered.range(of: #"url\(\s*['"]?\s*(https?:)?//"#, options: .regularExpression) != nil
    }
}
