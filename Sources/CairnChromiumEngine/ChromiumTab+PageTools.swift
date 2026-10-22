import AppKit
import CairnEngineKit
import CairnChromiumBridge

extension ChromiumTab: EngineTabPageTools {
    var hasDevTools: Bool { !closed && bridge.hasDevTools }

    func showDevTools(inspectingAt point: CGPoint?) {
        guard !closed else { return }
        if let point { bridge.showDevToolsInspectingPoint(point) } else { bridge.showDevTools() }
    }

    func closeDevTools() { if !closed { bridge.closeDevTools() } }

    func printPage() { if !closed { bridge.printPage() } }

    func printToPDF(at url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !closed, url.isFileURL else {
            completion(.failure(NSError(domain: "org.cairn.Chromium", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The page is closed or the destination is not a local file."])))
            return
        }
        bridge.printToPDF(atPath: url.path) { error in
            if let error { completion(.failure(error)) } else { completion(.success(())) }
        }
    }

    func setPagePreferences(_ preferences: PagePreferences) {
        bridge.setAcceptLanguage(preferences.acceptLanguages, userAgent: preferences.userAgent)
    }
}
