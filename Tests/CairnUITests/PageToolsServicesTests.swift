import AppKit
import Testing
import CairnCore
import CairnEngineKit
@testable import CairnUI

@MainActor
private final class PTEngine: BrowserEngine, EnginePagePreferences {
    let kind = EngineKind.chromium
    let displayName = "Test"
    let versionDescription = "1"
    var tabs: [PTTab] = []
    var pagePreferences = PagePreferences()
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab {
        let tab = PTTab()
        tab.state.url = initialURL
        tabs.append(tab)
        return tab
    }
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {}
    func shutdown() {}
}

@MainActor
private final class PTTab: EngineTabPageTools {
    let id = UUID()
    let view = NSView()
    var state = EngineTabState()
    weak var delegate: EngineTabDelegate?
    var zoom: Double = 1 {
        didSet { (delegate as? EngineTabZoomEvents)?.engineTab(self, zoomDidChange: zoom) }
    }
    var hasDevTools = false
    var inspected: [CGPoint?] = []
    var printed = 0
    var pdfTargets: [URL] = []
    var pdfResult: Result<Void, Error> = .success(())
    func load(_ url: URL) {
        state.url = url
        delegate?.engineTab(self, didChange: state)
    }
    func goBack() {}
    func goForward() {}
    func reload(ignoringCache: Bool) {}
    func stopLoading() {}
    func find(_ query: String, forward: Bool, completion: @escaping (Bool) -> Void) { completion(false) }
    func clearFind() {}
    func evaluateJavaScript(_ source: String, completion: ((Result<Any?, Error>) -> Void)?) { completion?(.success(nil)) }
    func setUserScripts(_ scripts: [EngineUserScript]) {}
    func takeSnapshot(completion: @escaping (NSImage?) -> Void) { completion(nil) }
    func close() {}
    func showDevTools(inspectingAt point: CGPoint?) { hasDevTools = true; inspected.append(point) }
    func closeDevTools() { hasDevTools = false }
    func printPage() { printed += 1 }
    func printToPDF(at url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        pdfTargets.append(url)
        completion(pdfResult)
    }
    func setPagePreferences(_ preferences: PagePreferences) {}
}

private struct PDFFailure: LocalizedError { var errorDescription: String? { "disk full" } }

@Suite(.serialized) @MainActor
struct PageToolsServicesTests {
    private func make(directory: URL? = nil) throws -> (BrowserServices, PTEngine, URL) {
        let directory = directory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/ui-pagetools-\(UUID().uuidString)")
        let engine = PTEngine()
        let registry = EngineRegistry()
        registry.register(.chromium) { engine }
        return (try BrowserServices.bootstrap(registry: registry, directory: directory), engine, directory)
    }

    private func navigate(_ services: BrowserServices, _ url: String) {
        services.model.navigate(url)
    }

    @Test func commandsAreRegistered() throws {
        let (services, _, directory) = try make()
        defer { services.shutdown(); try? FileManager.default.removeItem(at: directory) }
        navigate(services, "https://example.com")
        let ids = Set(services.commands().map(\.id))
        #expect(ids.isSuperset(of: ["ui.devtools", "ui.view-source", "ui.print", "ui.save-pdf",
                                  "ui.zoom-in", "ui.zoom-out", "ui.zoom-reset", "ui.reset-site-zoom"]))
    }

    @Test func devToolsToggleAndInspect() throws {
        let (services, engine, directory) = try make()
        defer { services.shutdown(); try? FileManager.default.removeItem(at: directory) }
        navigate(services, "https://example.com")
        let tab = try #require(engine.tabs.last)
        #expect(services.isEnabled(action: "ui.devtools"))
        services.perform(action: "ui.devtools")
        #expect(tab.hasDevTools)
        let command = try #require(services.commands().first { $0.id == "ui.devtools" })
        command.perform(services.model)
        #expect(!tab.hasDevTools)
        services.inspectElement(at: CGPoint(x: 4, y: 9))
        #expect(tab.inspected.last == CGPoint(x: 4, y: 9))
    }

    @Test func viewSourceOpensNewTabForWebPagesOnly() throws {
        let (services, _, directory) = try make()
        defer { services.shutdown(); try? FileManager.default.removeItem(at: directory) }
        navigate(services, "https://example.com/page")
        let before = services.model.selectedSpace.tabs.count
        #expect(services.isEnabled(action: "ui.view-source"))
        services.perform(action: "ui.view-source")
        #expect(services.model.selectedSpace.tabs.count == before + 1)
        #expect(services.model.selectedTab?.url?.absoluteString == "view-source:https://example.com/page")
        let count = services.model.selectedSpace.tabs.count
        #expect(!services.isEnabled(action: "ui.view-source"))
        services.perform(action: "ui.view-source")
        #expect(services.issues.isEmpty)
        services.viewSource()
        #expect(services.model.selectedSpace.tabs.count == count)
        #expect(services.issues.contains { $0.title == "View Source is unavailable" })
    }

    @Test func printAndPDFReachTheEngine() throws {
        let (services, engine, directory) = try make()
        defer { services.shutdown(); try? FileManager.default.removeItem(at: directory) }
        navigate(services, "https://example.com")
        let tab = try #require(engine.tabs.last)
        services.perform(action: "ui.print")
        #expect(tab.printed == 1)
        let target = directory.appendingPathComponent("out.pdf")
        services.exportPDF(to: target)
        #expect(tab.pdfTargets == [target])
        #expect(services.issues.isEmpty)
        tab.pdfResult = .failure(PDFFailure())
        services.exportPDF(to: target)
        #expect(services.issues.contains { $0.title == "The page could not be saved as PDF" && $0.detail.contains("disk full") })
    }

    @Test func savePDFActionUsesTheInitiatingTabAndReportsFailures() throws {
        let (services, engine, directory) = try make()
        defer { services.shutdown(); try? FileManager.default.removeItem(at: directory) }
        navigate(services, "https://example.com/report")
        let tab = try #require(engine.tabs.last)
        let target = directory.appendingPathComponent("report.pdf")
        tab.pdfResult = .failure(PDFFailure())
        services.pdfDestinationChooser = { filename in
            #expect(filename.hasSuffix(".pdf"))
            services.model.newTab(url: URL(string: "https://other.example"))
            return target
        }
        let command = try #require(services.commands().first { $0.id == "ui.save-pdf" })
        command.perform(services.model)
        #expect(tab.pdfTargets == [target])
        #expect(engine.tabs.last?.pdfTargets.isEmpty == true)
        #expect(services.issues.contains { $0.title == "The page could not be saved as PDF" && $0.detail.contains("disk full") })
        services.pdfDestinationChooser = { _ in nil }
    }

    @Test func cancelledPDFSaveDoesNotExportOrReportFailure() throws {
        let (services, engine, directory) = try make()
        defer { services.shutdown(); try? FileManager.default.removeItem(at: directory) }
        navigate(services, "https://example.com")
        var asked = 0
        services.pdfDestinationChooser = { _ in asked += 1; return nil }
        services.perform(action: "ui.save-pdf")
        #expect(asked == 1 && engine.tabs.last?.pdfTargets.isEmpty == true)
        #expect(services.issues.isEmpty)
    }

    @Test func pageToolActionsAreDisabledWithoutATabOrEngineCapability() throws {
        let workspace = Workspace(spaces: [Space(name: "Empty")])
        let services = BrowserServices(model: BrowserModel(engine: NullEngine.make(), workspace: workspace),
                                       directory: URL(fileURLWithPath: "/nonexistent-cairn"))
        var asked = false
        services.pdfDestinationChooser = { _ in asked = true; return nil }
        let ids = ["ui.devtools", "ui.print", "ui.save-pdf", "ui.view-source",
                   "ui.zoom-in", "ui.zoom-out", "ui.zoom-reset"]
        for id in ids {
            #expect(!services.isEnabled(action: id), "\(id)")
            services.perform(action: id)
            #expect(!services.commands().contains { $0.id == id })
        }
        #expect(!asked && services.issues.isEmpty)
        services.model.newTab(url: URL(string: "https://example.com"))
        for id in ["ui.devtools", "ui.print", "ui.save-pdf"] {
            #expect(!services.isEnabled(action: id))
            #expect(!services.commands().contains { $0.id == id })
        }
        #expect(services.isEnabled(action: "ui.view-source"))
        #expect(services.isEnabled(action: "ui.zoom-in"))
    }

    @Test func remappedAndClearedPageToolsAgreeAcrossMenusCommandsAndRelaunch() throws {
        let (services, _, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        navigate(services, "https://example.com")
        let custom = KeyChord("p", command: true, shift: true)
        try services.assignShortcut(custom, to: "ui.print")
        try services.assignShortcut(nil, to: "ui.devtools")
        #expect(services.commands().first { $0.id == "ui.print" }?.shortcut == custom.display)
        #expect(services.commands().first { $0.id == "ui.devtools" }?.shortcut == nil)
        let menu = MenuBuilder.menu(.file, map: services.shortcuts, target: NSObject(), action: #selector(NSObject.description))
        let item = try #require(menu.items.first { $0.representedObject as? String == "ui.print" })
        #expect(item.keyEquivalent == custom.keyEquivalent && item.keyEquivalentModifierMask == custom.modifierMask)
        services.shutdown()

        let (again, _, _) = try make(directory: directory)
        defer { again.shutdown() }
        navigate(again, "https://example.com")
        #expect(again.shortcuts.chord(for: "ui.print") == custom)
        #expect(again.commands().first { $0.id == "ui.print" }?.shortcut == custom.display)
        #expect(again.shortcuts.chord(for: "ui.devtools") == nil)
        #expect(again.commands().first { $0.id == "ui.devtools" }?.shortcut == nil)
    }

    @Test func zoomCommandsUseTheActionRouteInsteadOfLegacyModuleBindings() throws {
        let (services, engine, directory) = try make()
        defer { services.shutdown(); try? FileManager.default.removeItem(at: directory) }
        navigate(services, "https://example.com")
        let tab = try #require(engine.tabs.last)
        let custom = KeyChord("=", command: true, option: true)
        try services.assignShortcut(custom, to: "ui.zoom-in")
        let commands = services.commands()
        #expect(!commands.contains { $0.id.hasPrefix("cairn.zoom.") })
        let zoomIn = try #require(commands.first { $0.id == "ui.zoom-in" })
        #expect(zoomIn.shortcut == custom.display)
        services.setZoom(4)
        zoomIn.perform(services.model)
        #expect(abs(tab.zoom - 4.1) < 0.0001 && abs(services.zoom - 4.1) < 0.0001)
        services.perform(action: "ui.zoom-out")
        #expect(abs(tab.zoom - 4) < 0.0001)
        services.perform(action: "ui.zoom-reset")
        #expect(tab.zoom == 1 && services.zoom == 1)
        services.setZoom(2)
        try #require(commands.first { $0.id == "ui.reset-site-zoom" }).perform(services.model)
        #expect(tab.zoom == 1 && services.zoom == 1)
    }

    @Test func zoomFollowsTheSiteAndSurvivesRelaunch() throws {
        let (services, engine, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        navigate(services, "https://a.example/")
        let tab = try #require(engine.tabs.last)
        services.setZoom(1.5)
        #expect(tab.zoom == 1.5)
        navigate(services, "https://b.example/")
        #expect(tab.zoom == 1)
        #expect(services.zoom == 1)
        navigate(services, "https://a.example/other")
        #expect(abs(tab.zoom - 1.5) < 0.0001)
        #expect(abs(services.zoom - 1.5) < 0.0001)
        services.shutdown()

        let (again, engine2, _) = try make(directory: directory)
        defer { again.shutdown() }
        navigate(again, "https://a.example/")
        let reopened = try #require(engine2.tabs.last)
        #expect(abs(reopened.zoom - 1.5) < 0.0001)
        again.resetSiteZoom()
        #expect(reopened.zoom == 1)
    }

    @Test func settingsReachTheEngine() throws {
        let (services, engine, directory) = try make()
        defer { services.shutdown(); try? FileManager.default.removeItem(at: directory) }
        services.settings.acceptLanguages = "fr-CA, fr"
        services.settings.userAgent = "Custom/1.0"
        services.saveSettings()
        #expect(engine.pagePreferences == PagePreferences(acceptLanguages: "fr-CA,fr", userAgent: "Custom/1.0"))
    }
}
