import Foundation

/// Decides whether a link activated inside a tab opens as a Peek overlay. Pure, so it is testable without a browser.
public enum PeekPolicy {
    public enum Decision: Equatable, Sendable { case navigateNormally, peek }

    public static func decide(from source: URL?, to target: URL, sourceIsPinnedOrFavorite: Bool, enabled: Bool) -> Decision {
        guard enabled, sourceIsPinnedOrFavorite, URLResolver.isWebURL(target),
              let source, URLResolver.isWebURL(source) else { return .navigateNormally }
        if isAuthenticationOrPayment(target) { return .navigateNormally }
        return site(of: source) == site(of: target) ? .navigateNormally : .peek
    }

    private static let secondLevelSuffixes: Set<String> = ["co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au",
                                                           "co.jp", "co.nz", "co.in", "com.br", "com.cn", "co.za"]

    /// An approximate registrable domain (no public-suffix list): enough to tell example.com from evil.test.
    public static func site(of url: URL) -> String {
        let labels = (url.host ?? "").lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        return secondLevelSuffixes.contains(lastTwo) ? labels.suffix(3).joined(separator: ".") : lastTwo
    }

    private static let authHosts = ["accounts.google.com", "appleid.apple.com", "login.microsoftonline.com", "login.live.com",
                                    "paypal.com", "checkout.stripe.com", "js.stripe.com", "pay.google.com", "secure.checkout.visa.com",
                                    "id.apple.com", "auth0.com", "okta.com"]
    private static let authPathHints = ["/oauth", "/authorize", "/login/oauth", "/saml", "/sso", "/o/oauth2", "/signin/oauth", "/checkout", "/payment"]

    /// Sign-in and payment popups depend on `window.opener`, so they must never be turned into an overlay.
    public static func isAuthenticationOrPayment(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        if authHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        let path = url.path.lowercased()
        return authPathHints.contains { path.contains($0) }
    }
}

/// Peek overlay state: opened for a URL in a Space, then closed or expanded into a normal tab.
public struct PeekState: Equatable, Sendable {
    public private(set) var url: URL?
    public private(set) var spaceID: UUID?
    public var isOpen: Bool { url != nil }
    public init() {}

    public mutating func open(_ url: URL, in spaceID: UUID) { self.url = url; self.spaceID = spaceID }
    public mutating func close() { url = nil; spaceID = nil }

    /// Expanding hands the page to a Today tab in the Space and closes the overlay.
    @MainActor public mutating func expand(in model: BrowserModel) -> UUID? {
        guard let url, let spaceID else { return nil }
        close()
        return model.newTab(url: url, in: spaceID)
    }
}
