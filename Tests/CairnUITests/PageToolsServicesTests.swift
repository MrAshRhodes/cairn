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
        let ids = Set(services.commands().map(\.id))
        #expect(ids.isSuperset(of: ["ui.devtools", "ui.view-source", "ui.print", "ui.save-pdf"]))
    }

    @Test func devToolsToggleAndInspect() throws {
        let (services, engine, directory) = try make()
        defer { services.shutdown(); try? FileManager.default.removeItem(at: directory) }
        navigate(services, "https://example.com")
        let tab = try #require(engine.tabs.last)
        services.toggleDevTools()
        #expect(tab.hasDevTools)
        services.toggleDevTools()
        #expect(!tab.hasDevTools)
        services.inspectElement(at: CGPoint(x: 4, y: 9))
        #expect(tab.inspected.last == CGPoint(x: 4, y: 9))
    }

    @Test func viewSourceOpensNewTabForWebPagesOnly() throws {
        let (services, _, directory) = try make()
        defer { services.shutdown(); try? FileManager.default.removeItem(at: directory) }
        navigate(services, "https://example.com/page")
        let before = services.model.selectedSpace.tabs.count
        services.viewSource()
        #expect(services.model.selectedSpace.tabs.count == before + 1)
        #expect(services.model.selectedTab?.url?.absoluteString == "view-source:https://example.com/page")
        let count = services.model.selectedSpace.tabs.count
        services.viewSource()
        #expect(services.model.selectedSpace.tabs.count == count)
        #expect(services.issues.contains { $0.title == "View Source is unavailable" })
    }

    @Test func printAndPDFReachTheEngine() throws {
        let (services, engine, directory) = try make()
        defer { services.shutdown(); try? FileManager.default.removeItem(at: directory) }
        navigate(services, "https://example.com")
        let tab = try #require(engine.tabs.last)
        services.printPage()
        #expect(tab.printed == 1)
        let target = directory.appendingPathComponent("out.pdf")
        services.exportPDF(to: target)
        #expect(tab.pdfTargets == [target])
        #expect(services.issues.isEmpty)
        tab.pdfResult = .failure(PDFFailure())
        services.exportPDF(to: target)
        #expect(services.issues.contains { $0.title == "The page could not be saved as PDF" && $0.detail.contains("disk full") })
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
