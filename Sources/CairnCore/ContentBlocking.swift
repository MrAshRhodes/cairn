import Foundation
import Observation
import CairnEngineKit

/// Parses a user-supplied blocklist into host names. Accepted lines: a bare host, a hosts-file entry
/// (`0.0.0.0 host`), or an Adblock-style domain rule (`||host^`). Anything else (cosmetic rules, paths,
/// wildcards, exceptions, comments, IP addresses) is ignored, so a mixed list is safe to import.
public enum ContentBlocklist {
    public static let maximumHosts = 200_000
    public static let maximumBytes = 16 * 1024 * 1024

    public static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        var hosts: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let host = host(in: rawLine), seen.insert(host).inserted else { continue }
            hosts.append(host)
            if hosts.count >= maximumHosts { break }
        }
        return hosts
    }

    private static func host(in line: Substring) -> String? {
        var line = line.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("!") || line.hasPrefix("[") { return nil }
        if let comment = line.firstIndex(of: "#") { line = line[..<comment].trimmingCharacters(in: .whitespaces) }
        if line.hasPrefix("||") {
            guard let end = line.firstIndex(where: { $0 == "^" || $0 == "$" }) else { return nil }
            let tail = line[line.index(after: end)...]
            guard line[end] == "^" || tail.isEmpty else { return nil }
            return validHost(String(line.dropFirst(2)[..<end]))
        }
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        switch fields.count {
        case 1: return validHost(String(fields[0]))
        case 2 where ["0.0.0.0", "127.0.0.1", "::1", "::"].contains(String(fields[0])): return validHost(String(fields[1]))
        default: return nil
        }
    }

    /// A lower-case DNS name with at least one dot and no IP-address shape.
    public static func validHost(_ candidate: String) -> String? {
        let host = candidate.lowercased()
        guard host.count <= 253, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.")
        guard host.allSatisfy({ allowed.contains($0) }) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else { return nil }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return nil }
        return host
    }
}

/// The user's local blocklist and per-site exemptions. Nothing is downloaded: the list is imported from a file.
@MainActor @Observable
public final class ContentBlockingStore {
    public private(set) var isEnabled = false
    public private(set) var blockedHosts: [String] = []
    public private(set) var listName: String?
    public private(set) var exemptSites: [String] = []
    @ObservationIgnored public var onChange: (() -> Void)?

    public init() {}

    private struct Document: Codable {
        var schemaVersion = 1
        var isEnabled: Bool
        var listName: String?
        var blockedHosts: [String]
        var exemptSites: [String]
    }

    public var configuration: ContentBlockingConfiguration {
        ContentBlockingConfiguration(isEnabled: isEnabled, blockedHosts: blockedHosts, exemptSites: exemptSites)
    }

    public func isBlocking(on site: String) -> Bool { isEnabled && !exemptSites.contains(Self.normalized(site) ?? site) }

    public func setEnabled(_ enabled: Bool) { isEnabled = enabled; onChange?() }

    public func setBlocking(_ blocking: Bool, on site: String) {
        guard let site = Self.normalized(site) else { return }
        exemptSites.removeAll { $0 == site }
        if !blocking { exemptSites.append(site); exemptSites.sort() }
        onChange?()
    }

    /// Replaces the list with the hosts found in `text`. Throws when it contains none, leaving the old list.
    @discardableResult
    public func importList(_ text: String, name: String) throws -> Int {
        let hosts = ContentBlocklist.parse(text)
        guard !hosts.isEmpty else {
            throw ServiceError.invalidData("No blockable host names were found. Use one host per line, a hosts file, or `||host^` rules.")
        }
        blockedHosts = hosts
        listName = name
        onChange?()
        return hosts.count
    }

    public func removeList() { blockedHosts = []; listName = nil; onChange?() }

    public static func normalized(_ site: String) -> String? {
        let host = site.trimmingCharacters(in: .whitespaces).lowercased()
        return host.isEmpty ? nil : host
    }

    public static func load(from url: URL) throws -> ContentBlockingStore {
        let store = ContentBlockingStore()
        guard let data = try JSONStorage.read(url) else { return store }
        let document = try JSONStorage.decode(Document.self, from: data, schema: 1)
        store.isEnabled = document.isEnabled
        store.listName = document.listName
        store.blockedHosts = document.blockedHosts.compactMap(ContentBlocklist.validHost)
        store.exemptSites = document.exemptSites.compactMap(Self.normalized)
        return store
    }

    /// An existing unreadable or newer file is never replaced.
    public func save(to url: URL) throws {
        if let existing = try JSONStorage.read(url) { _ = try JSONStorage.decode(Document.self, from: existing, schema: 1) }
        try JSONStorage.write(Document(isEnabled: isEnabled, listName: listName, blockedHosts: blockedHosts,
                                       exemptSites: exemptSites), to: url)
    }
}
