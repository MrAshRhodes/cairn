import AppKit
import Testing
@testable import CairnModules
import CairnCore
import CairnEngineKit

@Suite @MainActor struct ModuleTests {
    @Test func loadingIsDeclarativeAndCommandsExecuteOnlyWhenSelected() throws {
        let fixture = try ModuleFixture()
        defer { fixture.remove() }
        try fixture.writeModule(commands: [
            ["id": "open", "title": "Open Example", "action": ["type": "openURL", "url": "https://example.com/"]],
            ["id": "navigate", "title": "Navigate", "action": ["type": "openURL", "url": "https://example.org/", "target": "currentTab"]],
        ])
        let engine = ModuleTestEngine()
        let model = BrowserModel(engine: engine)
        let registry = ModuleRegistry()
        try registry.loadUserModules(from: fixture.directory)
        #expect(engine.tabs.isEmpty)
        #expect(model.selectedTab == nil)
        #expect(registry.modules.map(\.id) == ["local.example"])
        let commands = registry.allCommands(for: model)
        try #require(commands.first { $0.id == "local.example.open" }).perform(model)
        #expect(model.selectedTab?.url?.host == "example.com")
        let selected = model.selectedTabID
        try #require(commands.first { $0.id == "local.example.navigate" }).perform(model)
        #expect(model.selectedTabID == selected)
        #expect(model.selectedTab?.url?.host == "example.org")
        #expect(engine.tabs.count == 1)
    }

    @Test func javaScriptNeedsExplicitTrustAndReportsEngineErrors() throws {
        let fixture = try ModuleFixture()
        defer { fixture.remove() }
        try fixture.writeModule(commands: [["id": "script", "title": "Script", "action": ["type": "javaScript", "source": "globalThis.customized = true;"]]])
        let engine = ModuleTestEngine()
        let model = BrowserModel(engine: engine)
        model.newTab(url: URL(string: "https://example.com"))
        let registry = ModuleRegistry()
        var errors: [String] = []
        registry.onError = { errors.append($0.localizedDescription) }
        try registry.loadUserModules(from: fixture.directory)
        let command = try #require(registry.allCommands(for: model).first)
        #expect(registry.requiresJavaScriptTrust(for: command.id))
        #expect(registry.javaScriptSource(for: command.id) == "globalThis.customized = true;")
        #expect(registry.javaScriptSource(for: "missing") == nil)
        command.perform(model)
        #expect(engine.tabs[0].evaluatedScripts.isEmpty)
        #expect(errors.last?.contains("explicit trust") == true)
        try registry.setJavaScriptTrusted(true, for: command.id)
        #expect(registry.isJavaScriptTrusted(for: command.id))
        command.perform(model)
        #expect(engine.tabs[0].evaluatedScripts.count == 1)
        #expect(engine.tabs[0].evaluatedScripts[0].contains("location.protocol"))
        engine.tabs[0].javaScriptError = ModuleError.invalid("script failed")
        command.perform(model)
        #expect(errors.last == "script failed")
        engine.tabs[0].state.url = URL(string: "file:///example")
        command.perform(model)
        #expect(engine.tabs[0].evaluatedScripts.count == 2)
        #expect(errors.last?.contains("HTTP or HTTPS") == true)
        registry.deactivate()
        #expect(!registry.isJavaScriptTrusted(for: command.id))
        command.perform(model)
        #expect(engine.tabs[0].evaluatedScripts.count == 2)
        #expect(throws: ModuleError.self) { try registry.setJavaScriptTrusted(true, for: "missing") }
    }

    @Test func invalidReloadIsTransactionalAndSuccessfulReloadRevokesTrust() throws {
        let fixture = try ModuleFixture()
        defer { fixture.remove() }
        try fixture.writeModule(commands: [["id": "script", "title": "Script", "action": ["type": "javaScript", "source": "1;"]]])
        let registry = ModuleRegistry()
        let model = BrowserModel(engine: ModuleTestEngine())
        try registry.loadUserModules(from: fixture.directory)
        _ = registry.allCommands(for: model)
        try registry.setJavaScriptTrusted(true, for: "local.example.script")
        try Data("{broken".utf8).write(to: fixture.directory.appendingPathComponent("bad.json"))
        #expect(throws: ModuleError.self) { try registry.loadUserModules(from: fixture.directory) }
        #expect(registry.modules.count == 1)
        #expect(registry.isJavaScriptTrusted(for: "local.example.script"))
        #expect(registry.lastError?.localizedDescription.contains("bad.json") == true)
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("bad.json"))
        try registry.loadUserModules(from: fixture.directory)
        #expect(!registry.isJavaScriptTrusted(for: "local.example.script"))
        #expect(registry.lastError == nil)
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("module.json"))
        try registry.loadUserModules(from: fixture.directory)
        #expect(registry.modules.isEmpty)
    }

    @Test(arguments: [
        ["type": "openURL", "url": "javascript:alert(1)"],
        ["type": "openURL", "url": "file:///etc/passwd"],
        ["type": "openURL", "url": "https://user:secret@example.com"],
        ["type": "openURL", "url": "https://example.com", "target": "shell"],
        ["type": "openURL", "url": "https://example.com\n.evil"],
        ["type": "openURL", "url": "https://example.com", "source": "execute()"],
        ["type": "executable", "path": "/bin/sh"],
        ["type": "javaScript", "source": ""],
        ["type": "javaScript", "source": "1;", "trusted": "true"],
    ])
    func malformedActionsAreRejected(action: [String: String]) throws {
        let fixture = try ModuleFixture()
        defer { fixture.remove() }
        try fixture.writeModule(commands: [["id": "command", "title": "Command", "action": action]])
        let registry = ModuleRegistry()
        #expect(throws: ModuleError.self) { try registry.loadUserModules(from: fixture.directory) }
        #expect(registry.modules.isEmpty)
    }

    @Test func invalidMetadataDuplicatesAndSymlinksAreRejected() throws {
        let fixture = try ModuleFixture()
        defer { fixture.remove() }
        let command: [String: Any] = ["id": "open", "title": "Open", "action": ["type": "openURL", "url": "https://example.com"]]
        let registry = ModuleRegistry()
        for id in ["", "cairn.fake", "CAIRN.fake", "bad/id", "bad\nid"] {
            try fixture.writeModule(id: id, commands: [command])
            #expect(throws: ModuleError.self) { try registry.loadUserModules(from: fixture.directory) }
        }
        try fixture.writeModule(commands: [command], schemaVersion: 2)
        #expect(throws: ModuleError.self) { try registry.loadUserModules(from: fixture.directory) }
        try fixture.writeModule(commands: [command, command])
        #expect(throws: ModuleError.self) { try registry.loadUserModules(from: fixture.directory) }
        try fixture.writeModule(commands: [command])
        let original = fixture.directory.appendingPathComponent("module.json")
        let duplicate = fixture.directory.appendingPathComponent("duplicate.json")
        try FileManager.default.copyItem(at: original, to: duplicate)
        #expect(throws: ModuleError.self) { try registry.loadUserModules(from: fixture.directory) }
        try FileManager.default.removeItem(at: duplicate)
        try FileManager.default.createSymbolicLink(at: duplicate, withDestinationURL: original)
        #expect(throws: ModuleError.self) { try registry.loadUserModules(from: fixture.directory) }
        #expect(registry.modules.isEmpty)
        #expect(throws: ModuleError.self) { try registry.loadUserModules(from: URL(string: "https://example.com")!) }
        #expect(throws: ModuleError.self) { try registry.loadUserModules(from: original) }
    }

    @Test func nonJSONFilesAreIgnoredAndMissingDirectoryIsEmpty() throws {
        let fixture = try ModuleFixture()
        defer { fixture.remove() }
        try Data("never execute this".utf8).write(to: fixture.directory.appendingPathComponent("plugin.dylib"))
        try Data("never execute this".utf8).write(to: fixture.directory.appendingPathComponent("plugin.swift"))
        try Data("invalid hidden manifest".utf8).write(to: fixture.directory.appendingPathComponent(".hidden.json"))
        let registry = ModuleRegistry()
        try registry.loadUserModules(from: fixture.directory)
        #expect(registry.modules.isEmpty)
        try registry.loadUserModules(from: fixture.directory.appendingPathComponent("missing"))
        #expect(registry.modules.isEmpty)
    }

    @Test func oversizeAndUnknownFieldsAreRejected() throws {
        let fixture = try ModuleFixture()
        defer { fixture.remove() }
        let registry = ModuleRegistry()
        let file = fixture.directory.appendingPathComponent("module.json")
        try Data(repeating: 32, count: 1_048_577).write(to: file)
        #expect(throws: ModuleError.self) { try registry.loadUserModules(from: fixture.directory) }
        #expect(registry.lastError?.localizedDescription.contains("1 MiB") == true)
        try Data(#"{"schemaVersion":1,"id":"local.test","name":"Test","version":"1","commands":[],"executable":"/bin/sh"}"#.utf8).write(to: file)
        #expect(throws: ModuleError.self) { try registry.loadUserModules(from: fixture.directory) }
        #expect(registry.modules.isEmpty)
    }

    @Test func deactivationRevokesEvenPreactivationTrust() throws {
        let fixture = try ModuleFixture()
        defer { fixture.remove() }
        try fixture.writeModule(commands: [["id": "script", "title": "Script", "action": ["type": "javaScript", "source": "1;"]]])
        let registry = ModuleRegistry()
        try registry.loadUserModules(from: fixture.directory)
        try registry.setJavaScriptTrusted(true, for: "local.example.script")
        registry.deactivate()
        #expect(!registry.isJavaScriptTrusted(for: "local.example.script"))
        let retained = try #require(registry.modules.first as? UserModule)
        try registry.setJavaScriptTrusted(true, for: "local.example.script")
        registry.unregister("local.example")
        #expect(!retained.isJavaScriptTrusted("local.example.script"))
    }

    @Test func shippedExampleLoadsWithoutExecuting() throws {
        let registry = ModuleRegistry()
        try registry.loadUserModules(from: ModuleFixture.repositoryRoot.appendingPathComponent("examples/modules"))
        #expect(registry.modules.map(\.id) == ["local.reading"])
        let engine = ModuleTestEngine()
        let model = BrowserModel(engine: engine)
        let command = try #require(registry.allCommands(for: model).first)
        #expect(!registry.requiresJavaScriptTrust(for: command.id))
        #expect(engine.tabs.isEmpty)
    }

    @Test func lifecycleAndDuplicateRegistrationAreDeterministic() throws {
        let registry = ModuleRegistry()
        let first = LifecycleModule(id: "test")
        let duplicate = LifecycleModule(id: "test")
        registry.register(first)
        registry.register(duplicate)
        #expect(registry.modules.count == 1)
        #expect(registry.lastError != nil)
        #expect(throws: ModuleError.self) { try registry.registerValidated(duplicate) }
        let model = BrowserModel(engine: ModuleTestEngine())
        registry.activate(model: model)
        registry.activate(model: model)
        _ = registry.allCommands(for: model)
        #expect(first.activations == 1)
        let second = LifecycleModule(id: "second")
        registry.register(second)
        #expect(second.activations == 1)
        #expect(registry.allCommands(for: model).count == 1)
        #expect(registry.lastError?.localizedDescription.contains("shared.command") == true)
        registry.unregister("test")
        #expect(first.deactivations == 1)
        registry.deactivate()
        registry.deactivate()
        #expect(second.deactivations == 1)
        #expect(duplicate.activations == 0)
    }

    @Test func builtinsExerciseTabsPinsArchiveSplitAndNavigation() throws {
        let engine = ModuleTestEngine()
        let model = BrowserModel(engine: engine)
        let registry = ModuleRegistry()
        BuiltinModules.all().forEach(registry.register)
        func run(_ id: String) throws {
            try #require(registry.allCommands(for: model).first { $0.id == id }).perform(model)
        }
        try run("cairn.tab.new")
        let first = try #require(model.selectedTabID)
        model.load(URL(string: "https://example.com")!, in: first)
        try run("cairn.tab.pin")
        #expect(model.locate(first)?.list == .pinned)
        model.load(URL(string: "https://example.org")!, in: first)
        try run("cairn.tab.reset")
        #expect(model.selectedTab?.url?.host == "example.com")
        try run("cairn.tab.pin")
        #expect(model.locate(first)?.list == .today)
        try run("cairn.tab.favorite")
        #expect(model.locate(first)?.list == .favorites)
        try run("cairn.tab.favorite")
        #expect(model.locate(first)?.list == .today)
        try run("cairn.tab.duplicate")
        #expect(model.selectedSpace.tabs.count == 2)
        let second = try #require(model.selectedTabID)
        #expect(first != second)
        try run("cairn.tab.previous")
        #expect(model.selectedTabID == first)
        try run("cairn.tab.next")
        #expect(model.selectedTabID == second)
        try run("cairn.split.open")
        #expect(Set(model.splitTabIDs) == Set([first, second]))
        try run("cairn.split.close")
        #expect(model.splitTabIDs.isEmpty)
        let live = try #require(model.liveTabs[second] as? ModuleTestTab)
        try run("cairn.navigation.reload")
        try run("cairn.navigation.reloadWithoutCache")
        try run("cairn.navigation.stop")
        try run("cairn.navigation.back")
        try run("cairn.navigation.forward")
        #expect(live.reloads == [false, true])
        #expect(live.stops == 1 && live.backs == 1 && live.forwards == 1)
        try run("cairn.zoom.in")
        #expect(abs(live.zoom - 1.1) < 0.0001)
        try run("cairn.zoom.reset")
        try run("cairn.zoom.out")
        #expect(abs(live.zoom - 0.9) < 0.0001)
        live.zoom = 3
        try run("cairn.zoom.in")
        #expect(live.zoom == 3)
        live.zoom = 0.25
        try run("cairn.zoom.out")
        #expect(live.zoom == 0.25)
        try run("cairn.tab.archive")
        #expect(model.locate(second)?.list == .archive)
        #expect(model.selectedTabID == first)
        #expect(live.closed)
        try run("cairn.archive.restore.\(second.uuidString)")
        #expect(model.selectedTabID == second)
        #expect(model.locate(second)?.list == .today)
        try run("cairn.tab.close")
        #expect(model.item(second) == nil)
        try run("cairn.space.new")
        #expect(model.workspace.spaces.count == 2)
    }

    @Test func splitAndArchiveWorkWithOnlyOneTab() throws {
        let model = BrowserModel(engine: ModuleTestEngine())
        let registry = ModuleRegistry()
        BuiltinModules.all().forEach(registry.register)
        let original = model.newTab()
        try #require(registry.allCommands(for: model).first { $0.id == "cairn.tab.archive" }).perform(model)
        #expect(model.locate(original)?.list == .archive)
        #expect(model.selectedTabID != original)
        #expect(model.selectedSpace.tabs.count == 1)
        try #require(registry.allCommands(for: model).first { $0.id == "cairn.split.open" }).perform(model)
        #expect(model.splitTabIDs.count == 2)
    }
}

struct ModuleFixture {
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory: URL
    init() throws {
        directory = Self.repositoryRoot
            .appendingPathComponent(".build/module-test-data/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func writeModule(id: String = "local.example", commands: [[String: Any]], schemaVersion: Int = 1) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": schemaVersion, "id": id, "name": "Local Example", "version": "1", "commands": commands,
        ])
        try data.write(to: directory.appendingPathComponent("module.json"))
    }
}

@MainActor private final class LifecycleModule: CairnModule {
    let id: String
    let displayName = "Lifecycle"
    let version = "1"
    var activations = 0
    var deactivations = 0
    init(id: String) { self.id = id }
    func activate(model: BrowserModel) { activations += 1 }
    func deactivate() { deactivations += 1 }
    func commands(for model: BrowserModel) -> [Command] { [Command(id: "shared.command", title: "Shared") { _ in }] }
}

@MainActor final class ModuleTestEngine: BrowserEngine {
    let kind = EngineKind.chromium
    let displayName = "Fake"
    let versionDescription = "Test"
    var tabs: [ModuleTestTab] = []
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab {
        let tab = ModuleTestTab()
        tab.state.url = initialURL
        tabs.append(tab)
        return tab
    }
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {}
    func shutdown() {}
}

@MainActor final class ModuleTestTab: EngineTab {
    let id = UUID()
    let view = NSView()
    var state = EngineTabState()
    weak var delegate: EngineTabDelegate?
    var zoom = 1.0
    var evaluatedScripts: [String] = []
    var javaScriptError: Error?
    var reloads: [Bool] = []
    var backs = 0
    var forwards = 0
    var stops = 0
    var closed = false
    func load(_ url: URL) { state.url = url }
    func goBack() { backs += 1 }
    func goForward() { forwards += 1 }
    func reload(ignoringCache: Bool) { reloads.append(ignoringCache) }
    func stopLoading() { stops += 1 }
    func find(_ query: String, forward: Bool, completion: @escaping (Bool) -> Void) { completion(false) }
    func clearFind() {}
    func evaluateJavaScript(_ source: String, completion: ((Result<Any?, Error>) -> Void)?) {
        evaluatedScripts.append(source)
        if let javaScriptError { completion?(.failure(javaScriptError)) } else { completion?(.success(nil)) }
    }
    func setUserScripts(_ scripts: [EngineUserScript]) {}
    func takeSnapshot(completion: @escaping (NSImage?) -> Void) { completion(nil) }
    func close() { closed = true }
}
