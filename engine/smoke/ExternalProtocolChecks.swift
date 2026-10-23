import CairnEngineKit
import Foundation

extension Smoke {
    func checkExternalProtocols(_ tab: EngineTab) async throws {
        let originalURL = tab.state.url
        _ = try await js(tab, "window.__externalProtocolDocument = 'preserved'; true")
        for target in ["mailto:smoke@example.com", "cairn-smoke-unknown://declined"] {
            let count = externalURLs.count
            _ = try await js(tab, "location.href = '\(target)'; true")
            try await wait { self.externalURLs.count > count && !tab.state.isLoading }
            // Cross both a renderer timer and browser callback turns, not just the handoff callback.
            let preserved = try await js(tab, """
                new Promise(resolve => setTimeout(() =>
                  resolve(window.__externalProtocolDocument === 'preserved'), 500))
                """) as? Bool
            try require(externalURLs.count == count + 1 && externalURLs.last?.absoluteString == target,
                        "external protocol is reported exactly once and Chromium never launches its handler")
            try require(preserved == true && tab.state.url == originalURL && tab.state.errorMessage == nil,
                        "handled or declined external protocol preserves the settled original page without a load error")
        }
        let failure = make("external-protocol-errors")
        failure.load(base.appendingPathComponent("network-failure"))
        try await wait { failure.state.errorMessage != nil }
        try require(failure.state.errorMessage != nil, "genuine HTTP navigation failure is still reported")
        failure.close()
    }
}
