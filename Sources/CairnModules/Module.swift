import Foundation
import CairnCore

// FROZEN API (see CairnEngineKit/Engine.swift for the rule).

/// An action shown in the command bar. Modules contribute these.
public struct Command: Identifiable, Sendable {
    public let id: String
    public var title: String
    public var subtitle: String?
    /// SF Symbol name.
    public var symbol: String?
    public var keywords: [String]
    /// Display-only shortcut hint, e.g. "⌘T".
    public var shortcut: String?
    public var perform: @MainActor @Sendable (BrowserModel) -> Void
    public init(id: String, title: String, subtitle: String? = nil, symbol: String? = nil, keywords: [String] = [],
                shortcut: String? = nil, perform: @escaping @MainActor @Sendable (BrowserModel) -> Void) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.symbol = symbol
        self.keywords = keywords; self.shortcut = shortcut; self.perform = perform
    }
}

/// The extension point. Built-in modules are Swift types listed in `ModuleRegistry.builtin()`; users can also drop
/// declarative script modules into `~/Library/Application Support/Cairn/Modules/` (see docs/EXTENDING.md).
@MainActor
public protocol CairnModule: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var version: String { get }
    func commands(for model: BrowserModel) -> [Command]
    func activate(model: BrowserModel)
    func deactivate()
}

public extension CairnModule {
    func activate(model: BrowserModel) {}
    func deactivate() {}
}

@MainActor
public final class ModuleRegistry {
    public static let shared = ModuleRegistry()
    public private(set) var modules: [CairnModule] = []
    public init() {}

    public func register(_ module: CairnModule) {
        modules.removeAll { $0.id == module.id }
        modules.append(module)
    }

    public func allCommands(for model: BrowserModel) -> [Command] {
        modules.flatMap { $0.commands(for: model) }
    }

    public func loadUserModules(from directory: URL) throws { throw ServiceError.notImplemented }
}

@MainActor
public enum BuiltinModules {
    public static func all() -> [CairnModule] { [] }
}
