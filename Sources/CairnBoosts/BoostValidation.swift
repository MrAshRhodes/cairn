import Foundation

public enum BoostError: LocalizedError {
    case invalid(String)
    case invalidHostPattern(String)
    case duplicateID(UUID)
    case notFound(UUID)
    case invalidFile(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .invalidHostPattern(let pattern):
            return "Invalid host pattern: \(pattern). Use an ASCII hostname, *.hostname, or an explicit *."
        case .duplicateID(let id): return "A Boost with ID \(id.uuidString) already exists."
        case .notFound(let id): return "No Boost with ID \(id.uuidString) exists."
        case .invalidFile(let reason): return "Could not load boosts.json: \(reason)"
        }
    }
}

public extension Boost {
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 512,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw BoostError.invalid("A Boost needs a nonempty name of at most 512 UTF-8 bytes without control characters.")
        }
        guard !hostPatterns.isEmpty, hostPatterns.count <= 100 else {
            throw BoostError.invalid("A Boost needs 1–100 explicit host patterns.")
        }
        guard css.utf8.count <= 256 * 1024, js.utf8.count <= 256 * 1024 else {
            throw BoostError.invalid("Boost CSS and JavaScript are each limited to 256 KiB.")
        }
        for pattern in hostPatterns { _ = try BoostHostPattern(pattern) }
    }

    /// Matching is scheme- and label-boundary-aware. Invalid patterns never match.
    /// The enabled flag is intentionally separate, so editors can preview a disabled Boost's scope.
    func matches(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return false }
        return hostPatterns.contains { (try? BoostHostPattern($0))?.matches(host) == true }
    }
}

struct BoostHostPattern {
    let host: String
    let subdomainsOnly: Bool
    let allHosts: Bool

    init(_ value: String) throws {
        allHosts = value == "*"
        subdomainsOnly = value.hasPrefix("*.")
        let base = subdomainsOnly ? String(value.dropFirst(2)) : value
        host = Self.canonicalHost(base)
        if allHosts { return }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard base.utf8.allSatisfy({ $0 < 128 }), !host.isEmpty, host.utf8.count <= 253,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                      label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { throw BoostError.invalidHostPattern(value) }
    }

    func matches(_ candidate: String) -> Bool {
        let candidate = Self.canonicalHost(candidate)
        return !candidate.isEmpty && (allHosts || (!subdomainsOnly && candidate == host) || candidate.hasSuffix("." + host))
    }

    static func canonicalHost(_ host: String) -> String {
        let lowered = host.lowercased()
        return lowered.hasSuffix(".") ? String(lowered.dropLast()) : lowered
    }
}
