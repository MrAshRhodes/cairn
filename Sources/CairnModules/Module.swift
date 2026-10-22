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

/// The extension point. Built-in modules are Swift types listed in `BuiltinModules.all()`; users can also drop
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
    public private(set) var lastError: Error?
    public var onError: ((Error) -> Void)?
    private weak var activeModel: BrowserModel?
    private var userModuleIDs: Set<String> = []
    public init() {}

    /// First registration wins. Use `registerValidated` when the caller needs a throwing API.
    public func register(_ module: CairnModule) {
        do { try registerValidated(module) } catch { report(error) }
    }

    public func registerValidated(_ module: CairnModule) throws {
        guard !module.id.isEmpty else { throw ModuleError.invalid("A module ID is required.") }
        guard !modules.contains(where: { $0.id == module.id }) else {
            throw ModuleError.duplicateID(module.id)
        }
        modules.append(module)
        if let activeModel { module.activate(model: activeModel) }
    }

    public func activate(model: BrowserModel) {
        guard activeModel !== model else { return }
        if activeModel != nil { deactivate() }
        activeModel = model
        modules.forEach { $0.activate(model: model) }
    }

    public func deactivate() {
        for module in modules {
            if activeModel != nil { module.deactivate() }
            else { (module as? UserModule)?.revokeJavaScriptTrust() }
        }
        activeModel = nil
    }

    public func unregister(_ id: String) {
        guard let index = modules.firstIndex(where: { $0.id == id }) else { return }
        if activeModel != nil { modules[index].deactivate() }
        else { (modules[index] as? UserModule)?.revokeJavaScriptTrust() }
        modules.remove(at: index)
        userModuleIDs.remove(id)
    }

    public func allCommands(for model: BrowserModel) -> [Command] {
        activate(model: model)
        var seen: Set<String> = []
        return modules.flatMap { $0.commands(for: model) }.filter {
            guard !$0.id.isEmpty, seen.insert($0.id).inserted else {
                report(ModuleError.duplicateID($0.id))
                return false
            }
            return true
        }
    }

    /// Validates the entire directory before replacing previously loaded user modules.
    /// Reading a manifest never evaluates JavaScript or performs its URL commands.
    public func loadUserModules(from directory: URL) throws {
        do {
            let loaded = try UserModuleLoader.load(from: directory)
            let builtInIDs = Set(modules.filter { !userModuleIDs.contains($0.id) }.map(\.id))
            var moduleIDs = builtInIDs
            var commandIDs: Set<String> = []
            for definition in loaded {
                guard moduleIDs.insert(definition.id).inserted else {
                    throw ModuleError.duplicateID(definition.id)
                }
                for command in definition.commands {
                    let id = definition.id + "." + command.id
                    guard commandIDs.insert(id).inserted else { throw ModuleError.duplicateID(id) }
                }
            }
            for id in userModuleIDs { unregister(id) }
            for definition in loaded {
                let module = UserModule(definition: definition) { [weak self] in self?.report($0) }
                try registerValidated(module)
                userModuleIDs.insert(module.id)
            }
            lastError = nil
        } catch {
            report(error)
            throw error
        }
    }

    /// Trust is an explicit in-memory grant, never a value a JSON manifest can grant itself.
    /// Reloading modules or deactivating the registry revokes JavaScript grants.
    public func setJavaScriptTrusted(_ trusted: Bool, for commandID: String) throws {
        for case let module as UserModule in modules where module.containsJavaScript(commandID) {
            module.setJavaScriptTrusted(trusted, commandID: commandID)
            return
        }
        throw ModuleError.unknownCommand(commandID)
    }

    public func isJavaScriptTrusted(for commandID: String) -> Bool {
        modules.compactMap { $0 as? UserModule }.contains { $0.isJavaScriptTrusted(commandID) }
    }

    public func requiresJavaScriptTrust(for commandID: String) -> Bool {
        modules.compactMap { $0 as? UserModule }.contains { $0.containsJavaScript(commandID) }
    }

    /// The exact loaded source to show in a trust confirmation, without evaluating it.
    public func javaScriptSource(for commandID: String) -> String? {
        modules.compactMap { ($0 as? UserModule)?.javaScriptSource(commandID) }.first
    }

    private func report(_ error: Error) {
        lastError = error
        onError?(error)
    }
}

@MainActor
public enum BuiltinModules {
    public static func all() -> [CairnModule] { [BrowserCommandsModule(), MediaModule()] }
}
