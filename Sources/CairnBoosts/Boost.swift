import Foundation
import CairnEngineKit

// FROZEN data shape (see CairnEngineKit/Engine.swift for the rule).

/// A per-site customization: CSS and/or JavaScript applied on pages whose host matches one of `hostPatterns`
/// ("example.com" matches the host and its subdomains; "*.example.com" matches subdomains only;
/// "*" explicitly matches every HTTP(S) host). JavaScript requires a separate, session-only trust grant.
public struct Boost: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var hostPatterns: [String]
    public var css: String
    public var js: String
    public var isEnabled: Bool
    public init(id: UUID = UUID(), name: String, hostPatterns: [String], css: String = "", js: String = "", isEnabled: Bool = true) {
        self.id = id; self.name = name; self.hostPatterns = hostPatterns; self.css = css; self.js = js; self.isEnabled = isEnabled
    }
}
