import Foundation
import Darwin

/// Site classification only, never an origin, cookie, permission or navigation-security boundary.
/// Both ICANN and PRIVATE public suffixes come from a bundled, versioned PSL; no network is used.
public enum SiteMatching {
    public static func site(of url: URL) -> String? {
        guard URLResolver.isWebURL(url), var host = url.host?.lowercased() else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if host.contains(":") {
            var address = in6_addr()
            let literal = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
            guard literal.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return "[\(String(cString: buffer))]"
        }
        var address = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 { return host }
        return PublicSuffixList.bundled.registrableDomain(host) ?? host
    }

    public static func isSameSite(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = site(of: lhs), let right = site(of: rhs) else { return false }
        return left == right
    }
}

struct PublicSuffixList {
    private let exact: Set<String>
    private let wildcard: Set<String>
    private let exception: Set<String>

    static let bundled: PublicSuffixList = {
        guard let url = Bundle.module.url(forResource: "public_suffix_list", withExtension: "dat", subdirectory: "PublicSuffix"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("The bundled public suffix list is missing. Reinstall Cairn from a complete release.")
        }
        return PublicSuffixList(text: text)
    }()

    init(text: String) {
        var exact = Set<String>(), wildcard = Set<String>(), exception = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let rule = line.trimmingCharacters(in: .whitespaces)
            guard !rule.isEmpty, !rule.hasPrefix("//") else { continue }
            let isException = rule.hasPrefix("!")
            let isWildcard = rule.hasPrefix("*.")
            let domain = String(rule.dropFirst(isException ? 1 : isWildcard ? 2 : 0))
            // URL.host and navigation use the same IDNA conversion; the PSL itself contains Unicode.
            guard let host = URL(string: "https://\(domain)")?.host?.lowercased() else { continue }
            if isException { exception.insert(host) }
            else if isWildcard { wildcard.insert(host) }
            else { exact.insert(host) }
        }
        self.exact = exact; self.wildcard = wildcard; self.exception = exception
    }

    /// Input is an already validated, IDNA-normalized DNS name. A suffix alone has no registrable domain.
    func registrableDomain(_ host: String) -> String? {
        let labels = host.split(separator: ".")
        var suffixCount = 1 // The PSL's implicit "*" rule also covers unknown TLDs.
        for index in labels.indices {
            let suffix = labels[index...].joined(separator: ".")
            if exception.contains(suffix) {
                suffixCount = labels.count - index - 1
                break
            }
            if exact.contains(suffix) { suffixCount = max(suffixCount, labels.count - index) }
            if index > 0, wildcard.contains(suffix) { suffixCount = max(suffixCount, labels.count - index + 1) }
        }
        guard labels.count > suffixCount else { return nil }
        return labels.suffix(suffixCount + 1).joined(separator: ".")
    }
}
