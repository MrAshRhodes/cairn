import Foundation
import CairnCore

public enum ModuleError: LocalizedError {
    case invalid(String)
    case invalidFile(String, String)
    case duplicateID(String)
    case unknownCommand(String)
    case javaScriptNotTrusted(String)
    case noWebPage

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .invalidFile(let file, let reason): return "\(file): \(reason)"
        case .duplicateID(let id): return "Duplicate module or command ID: \(id). The existing registration was kept."
        case .unknownCommand(let id): return "No JavaScript command named \(id) is loaded."
        case .javaScriptNotTrusted(let id): return "JavaScript command \(id) needs explicit trust before it can run."
        case .noWebPage: return "JavaScript commands can run only in a selected HTTP or HTTPS page."
        }
    }
}

struct UserModuleDefinition: Decodable {
    let schemaVersion: Int
    let id: String
    let name: String
    let version: String
    let commands: [UserCommandDefinition]
}

struct UserCommandDefinition: Decodable {
    let id: String
    let title: String
    let subtitle: String?
    let symbol: String?
    let keywords: [String]?
    let shortcut: String?
    let action: UserCommandAction
}

enum UserCommandAction: Decodable {
    case openURL(URL, newTab: Bool)
    case javaScript(String)

    enum CodingKeys: String, CodingKey { case type, url, target, source }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "openURL":
            let text = try values.decode(String.self, forKey: .url)
            let target = try values.decodeIfPresent(String.self, forKey: .target) ?? "newTab"
            guard ["newTab", "currentTab"].contains(target),
                  !values.contains(.source),
                  !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
                  let url = URL(string: text),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
                throw ModuleError.invalid("openURL requires an absolute HTTP(S) URL without credentials and a newTab/currentTab target.")
            }
            self = .openURL(url, newTab: target == "newTab")
        case "javaScript":
            let source = try values.decode(String.self, forKey: .source)
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  source.utf8.count <= 256 * 1024, !values.contains(.url), !values.contains(.target) else {
                throw ModuleError.invalid("javaScript requires nonempty source (at most 256 KiB), without URL fields.")
            }
            self = .javaScript(source)
        default:
            throw ModuleError.invalid("Only openURL and javaScript actions are supported.")
        }
    }
}

enum UserModuleLoader {
    static let maximumFileSize = 1_048_576

    static func load(from directory: URL) throws -> [UserModuleDefinition] {
        guard directory.isFileURL else { throw ModuleError.invalid("Modules must be loaded from a local directory.") }
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { throw ModuleError.invalid("The Modules path is not a directory.") }
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                                                   options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count <= 128 else { throw ModuleError.invalid("At most 128 local module files can be loaded.") }
        return try files.map { file in
            do {
                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true,
                      let size = info.fileSize, size <= maximumFileSize else {
                    throw ModuleError.invalid("Expected a regular JSON file no larger than 1 MiB; symbolic links are not loaded.")
                }
                let data = try Data(contentsOf: file)
                guard data.count <= maximumFileSize else { throw ModuleError.invalid("Module file exceeds 1 MiB.") }
                try validateKeys(data)
                let definition = try JSONDecoder().decode(UserModuleDefinition.self, from: data)
                try validate(definition)
                return definition
            } catch {
                throw ModuleError.invalidFile(file.lastPathComponent, error.localizedDescription)
            }
        }
    }

    private static func validateKeys(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys).isSubset(of: ["schemaVersion", "id", "name", "version", "commands"]),
              let commands = root["commands"] as? [[String: Any]] else {
            throw ModuleError.invalid("Expected a module object with schemaVersion, id, name, version and commands; unknown fields are not allowed.")
        }
        for command in commands {
            guard Set(command.keys).isSubset(of: ["id", "title", "subtitle", "symbol", "keywords", "shortcut", "action"]),
                  let action = command["action"] as? [String: Any],
                  Set(action.keys).isSubset(of: ["type", "url", "target", "source"]) else {
                throw ModuleError.invalid("Unknown or malformed command/action fields.")
            }
        }
    }

    private static func validate(_ definition: UserModuleDefinition) throws {
        guard definition.schemaVersion == 1 else { throw ModuleError.invalid("Unsupported module schemaVersion; expected 1.") }
        guard validID(definition.id), !definition.id.lowercased().hasPrefix("cairn.") else {
            throw ModuleError.invalid("Use a module ID of 1–128 ASCII letters, digits, dots, hyphens or underscores. The cairn. prefix is reserved.")
        }
        guard validText(definition.name), validText(definition.version),
              !definition.commands.isEmpty, definition.commands.count <= 100 else {
            throw ModuleError.invalid("A name, version and 1–100 commands are required.")
        }
        var ids: Set<String> = []
        for command in definition.commands {
            guard validID(command.id), validText(command.title),
                  [command.subtitle, command.symbol, command.shortcut].compactMap({ $0 }).allSatisfy({ validText($0) }),
                  (command.keywords ?? []).count <= 32,
                  (command.keywords ?? []).allSatisfy({ validText($0) }) else {
                throw ModuleError.invalid("Command IDs and display fields must be nonempty and within their length limits.")
            }
            guard ids.insert(command.id).inserted else { throw ModuleError.duplicateID(definition.id + "." + command.id) }
        }
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 &&
            value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }
    }

    private static func validText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 512 &&
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

@MainActor
final class UserModule: CairnModule {
    let definition: UserModuleDefinition
    let reportError: (Error) -> Void
    private weak var activeModel: BrowserModel?
    private var trustedCommands: Set<String> = []
    var id: String { definition.id }
    var displayName: String { definition.name }
    var version: String { definition.version }

    init(definition: UserModuleDefinition, reportError: @escaping (Error) -> Void) {
        self.definition = definition
        self.reportError = reportError
    }

    func activate(model: BrowserModel) { activeModel = model }
    func deactivate() { activeModel = nil; revokeJavaScriptTrust() }
    func revokeJavaScriptTrust() { trustedCommands.removeAll() }

    func containsJavaScript(_ commandID: String) -> Bool {
        javaScriptSource(commandID) != nil
    }

    func javaScriptSource(_ commandID: String) -> String? {
        guard let command = definition.commands.first(where: { id + "." + $0.id == commandID }),
              case .javaScript(let source) = command.action else { return nil }
        return source
    }

    func setJavaScriptTrusted(_ trusted: Bool, commandID: String) {
        if trusted { trustedCommands.insert(commandID) } else { trustedCommands.remove(commandID) }
    }

    func isJavaScriptTrusted(_ commandID: String) -> Bool { trustedCommands.contains(commandID) }

    func commands(for model: BrowserModel) -> [Command] {
        definition.commands.map { definition in
            let commandID = id + "." + definition.id
            return Command(id: commandID, title: definition.title, subtitle: definition.subtitle,
                           symbol: definition.symbol, keywords: definition.keywords ?? [], shortcut: definition.shortcut) { [weak self] model in
                guard let self, self.activeModel === model else { return }
                switch definition.action {
                case .openURL(let url, let newTab):
                    if newTab { model.newTab(url: url) }
                    else if let id = model.selectedTabID { model.load(url, in: id) }
                    else { model.newTab(url: url) }
                case .javaScript(let source):
                    guard self.trustedCommands.contains(commandID) else {
                        self.reportError(ModuleError.javaScriptNotTrusted(commandID))
                        return
                    }
                    guard let id = model.selectedTabID, let tab = model.liveTab(for: id),
                          let url = tab.state.url,
                          ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                        self.reportError(ModuleError.noWebPage)
                        return
                    }
                    // Recheck inside the document as it may have navigated since the engine state was read.
                    let guarded = """
                    (function () {
                        if (location.protocol !== "http:" && location.protocol !== "https:") return;
                        \(source)
                    })();
                    """
                    tab.evaluateJavaScript(guarded) { [weak self] result in
                        if case .failure(let error) = result { self?.reportError(error) }
                    }
                }
            }
        }
    }
}
