import Foundation

/// Decides whether a link activated inside a tab opens as a Peek overlay. Pure, so it is testable without a browser.
public enum PeekPolicy {
    public enum Decision: Equatable, Sendable { case navigateNormally, peek }

    public static func decide(from source: URL?, to target: URL, sourceIsPinnedOrFavorite: Bool, enabled: Bool) -> Decision {
        guard enabled, sourceIsPinnedOrFavorite, URLResolver.isWebURL(target),
              let source, URLResolver.isWebURL(source) else { return .navigateNormally }
        if isAuthenticationOrPayment(source) || isAuthenticationOrPayment(target) { return .navigateNormally }
        guard SiteMatching.site(of: source) != nil, SiteMatching.site(of: target) != nil else { return .navigateNormally }
        return SiteMatching.isSameSite(source, target) ? .navigateNormally : .peek
    }

    /// Compatibility wrapper; use `SiteMatching` when an invalid or non-web URL must be distinguished.
    public static func site(of url: URL) -> String {
        SiteMatching.site(of: url) ?? ""
    }

    private static let authHosts = ["accounts.google.com", "appleid.apple.com", "login.microsoftonline.com", "login.live.com",
                                    "paypal.com", "checkout.stripe.com", "js.stripe.com", "pay.google.com", "secure.checkout.visa.com",
                                    "id.apple.com", "auth0.com", "okta.com"]
    private static let authPathHints = ["/oauth", "/authorize", "/login", "/signin", "/sign-in", "/saml", "/sso",
                                        "/o/oauth2", "/auth/", "/callback", "/checkout", "/payment"]
    private static let authQueryHints: Set<String> = ["client_id", "redirect_uri", "response_type",
                                                     "code", "id_token", "access_token", "payment_intent"]

    /// Sign-in and payment popups depend on `window.opener`, so they must never be turned into an overlay.
    public static func isAuthenticationOrPayment(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        if authHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        let path = url.path.lowercased()
        if authPathHints.contains(where: { path.contains($0) }) { return true }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
            authQueryHints.contains($0.name.lowercased())
        } ?? false
    }
}

/// Peek overlay state: opened for a URL in a Space, then closed or expanded into a normal tab.
public struct PeekState: Equatable, Sendable {
    public private(set) var url: URL?
    public private(set) var spaceID: UUID?
    public private(set) var tabID: UUID?
    public private(set) var ownerTabID: UUID?
    public var isOpen: Bool { url != nil }
    public init() {}

    public mutating func open(_ url: URL, in spaceID: UUID, tabID: UUID? = nil, ownerTabID: UUID? = nil) {
        self.url = url; self.spaceID = spaceID; self.tabID = tabID; self.ownerTabID = ownerTabID
    }
    public mutating func close() { url = nil; spaceID = nil; tabID = nil; ownerTabID = nil }

    /// Expanding hands the page to a Today tab in the Space and closes the overlay.
    @MainActor public mutating func expand(in model: BrowserModel) -> UUID? {
        guard let tabID, let spaceID, model.transientPages[tabID] != nil else { return nil }
        var promoted: UUID?
        model.promoteTransient(tabID, to: spaceID) { promoted = $0 }
        if promoted != nil { close() }
        return promoted
    }
}
