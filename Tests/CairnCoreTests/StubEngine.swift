import AppKit
import CairnEngineKit
@testable import CairnCore

@MainActor
final class StubEngine: BrowserEngine {
    let kind = EngineKind.chromium
    let displayName = "Stub"
    let versionDescription = "Test"
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab { StubTab() }
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {}
    func shutdown() {}
}

@MainActor
final class StubTab: EngineTab {
    let id = UUID()
    let view = NSView()
    var state = EngineTabState()
    weak var delegate: EngineTabDelegate?
    var zoom: Double = 1
    func load(_ url: URL) {}
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
}
