import Foundation
import Observation
import CairnEngineKit

@MainActor @Observable
public final class BoostStore {
    public private(set) var boosts: [Boost] = []
    public let directory: URL
    public private(set) var trustedJavaScriptIDs: Set<UUID> = []
    private var hasLoaded = false
    private static let maximumFileSize = 8 * 1_048_576
    private var fileURL: URL { directory.appendingPathComponent("boosts.json") }

    public init(directory: URL) { self.directory = directory }

    public func load() throws {
        try validateDirectory()
        let manager = FileManager.default
        do {
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try manager.attributesOfItem(atPath: fileURL.path)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                boosts = []
                trustedJavaScriptIDs.removeAll()
                hasLoaded = true
                return
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumFileSize else {
                throw BoostError.invalid("Expected a regular JSON file of at most 8 MiB, not a symbolic link.")
            }
            let data = try Data(contentsOf: fileURL)
            guard data.count <= Self.maximumFileSize else { throw BoostError.invalid("The file exceeds 8 MiB.") }
            let document = try JSONDecoder().decode(BoostDocument.self, from: data)
            guard document.schemaVersion == 1 else { throw BoostError.invalid("Unsupported schemaVersion; expected 1.") }
            try validate(document.boosts)
            boosts = document.boosts
            trustedJavaScriptIDs.removeAll()
            hasLoaded = true
        } catch {
            throw BoostError.invalidFile(error.localizedDescription)
        }
    }

    public func save() throws {
        if !hasLoaded { try load() }
        try persist(boosts)
    }

    public func add(_ boost: Boost) throws {
        try boost.validate()
        if !hasLoaded { try load() }
        guard !boosts.contains(where: { $0.id == boost.id }) else { throw BoostError.duplicateID(boost.id) }
        let updated = boosts + [boost]
        try persist(updated)
        boosts = updated
    }

    public func update(_ boost: Boost) throws {
        try boost.validate()
        if !hasLoaded { try load() }
        guard let index = boosts.firstIndex(where: { $0.id == boost.id }) else { throw BoostError.notFound(boost.id) }
        var updated = boosts
        updated[index] = boost
        try persist(updated)
        if boosts[index].js != boost.js || boosts[index].hostPatterns != boost.hostPatterns {
            trustedJavaScriptIDs.remove(boost.id)
        }
        boosts = updated
    }

    public func remove(_ id: UUID) throws {
        if !hasLoaded { try load() }
        guard boosts.contains(where: { $0.id == id }) else { throw BoostError.notFound(id) }
        let updated = boosts.filter { $0.id != id }
        try persist(updated)
        boosts = updated
        trustedJavaScriptIDs.remove(id)
    }

    public func setEnabled(_ enabled: Bool, for id: UUID) throws {
        if !hasLoaded { try load() }
        guard var boost = boosts.first(where: { $0.id == id }) else { throw BoostError.notFound(id) }
        boost.isEnabled = enabled
        try update(boost)
    }

    /// Call only after the user reviews locally authored source and explicitly opts in.
    /// Trust is not stored in JSON and is revoked on reload or changes to source/scope.
    public func setJavaScriptTrusted(_ trusted: Bool, for id: UUID) throws {
        if !hasLoaded { try load() }
        guard boosts.contains(where: { $0.id == id }) else { throw BoostError.notFound(id) }
        if trusted { trustedJavaScriptIDs.insert(id) } else { trustedJavaScriptIDs.remove(id) }
    }

    /// Return all enabled scripts, even for nil/non-web initial URLs. An engine retains these
    /// across navigations; runtime guards decide whether each new HTTP(S) document matches.
    public func scripts(for url: URL?) -> [EngineUserScript] {
        boosts.filter(\.isEnabled).compactMap { boost in
            guard (try? boost.validate()) != nil else { return nil }
            let javaScript = trustedJavaScriptIDs.contains(boost.id) ? boost.js : ""
            guard !boost.effectiveCSS.isEmpty || !javaScript.isEmpty else { return nil }
            guard let patterns = try? boost.hostPatterns.map({ try BoostHostPattern($0) }),
                  let encodedPatterns = try? Self.json(patterns.map {
                      ScriptPattern(host: $0.host, subdomainsOnly: $0.subdomainsOnly, allHosts: $0.allHosts)
                  }),
                  let encodedCSS = try? Self.json(boost.effectiveCSS),
                  let styleID = try? Self.json("cairn-boost-" + boost.id.uuidString.lowercased()) else { return nil }
            let source = """
            (function () {
                "use strict";
                if (location.protocol !== "http:" && location.protocol !== "https:") return;
                const host = location.hostname.toLowerCase().replace(/\\.$/, "");
                const patterns = \(encodedPatterns);
                if (!host || !patterns.some(function (p) {
                    return p.allHosts || (!p.subdomainsOnly && host === p.host) || host.endsWith("." + p.host);
                })) return;
                const css = \(encodedCSS);
                if (css) {
                    const id = \(styleID);
                    let style = document.getElementById(id);
                    if (!style) {
                        style = document.createElement("style");
                        style.id = id;
                        (document.head || document.documentElement).appendChild(style);
                    }
                    style.textContent = css;
                }
                \(javaScript)
            })();
            """
            return EngineUserScript(id: "cairn.boost." + boost.id.uuidString, source: source, injection: .documentEnd)
        }
    }

    private func validateDirectory() throws {
        guard directory.isFileURL else { throw BoostError.invalid("Boosts must be stored in a local directory.") }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw BoostError.invalid("The Boosts path is not a directory.")
        }
    }

    private func validate(_ values: [Boost]) throws {
        guard values.count <= 1_000 else { throw BoostError.invalid("At most 1,000 Boosts can be stored.") }
        var seen: Set<UUID> = []
        for boost in values {
            try boost.validate()
            guard seen.insert(boost.id).inserted else { throw BoostError.duplicateID(boost.id) }
        }
    }

    private func persist(_ values: [Boost]) throws {
        try validateDirectory()
        try validate(values)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(BoostDocument(schemaVersion: 1, boosts: values))
        guard data.count <= Self.maximumFileSize else { throw BoostError.invalid("Boosts exceed the 8 MiB storage limit.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Atomic replacement uses a sibling file, so a failed write never publishes a half-written document.
        try data.write(to: fileURL, options: [.atomic])
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
    }
}

private struct BoostDocument: Codable {
    let schemaVersion: Int
    let boosts: [Boost]
}

private struct ScriptPattern: Encodable {
    let host: String
    let subdomainsOnly: Bool
    let allHosts: Bool
}
