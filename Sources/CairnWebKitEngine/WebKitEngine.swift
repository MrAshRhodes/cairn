import Foundation
import CairnEngineKit

// STUB — replaced by the ENGINE-WK agent (WKWebView-backed implementation of BrowserEngine).
public enum WebKitEngineModule {
    public static let kind: EngineKind = .webkit
    @MainActor public static func register(in registry: EngineRegistry) {}
}
