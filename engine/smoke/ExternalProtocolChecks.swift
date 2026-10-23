import CairnEngineKit
import Foundation

extension Smoke {
    func checkExternalProtocols(_ tab: EngineTab) async throws {
        func progress(_ phase: StaticString, targetIndex: Int = -1) {
            // Synthetic phase/index only: do not print evaluated JavaScript or navigation URLs.
            fputs("CAIRN_SMOKE_EXTERNAL t=\(ProcessInfo.processInfo.systemUptime) phase=\(phase) case=\(targetIndex)\n", stderr)
            fflush(stderr)
        }
        let originalURL = tab.state.url
        progress("marker.begin")
        _ = try await js(tab, "window.__externalProtocolDocument = 'preserved'; true")
        progress("marker.end")
        for (index, target) in ["mailto:smoke@example.com", "cairn-smoke-unknown://declined"].enumerated() {
            let count = externalURLs.count
            progress("assign.begin", targetIndex: index)
            _ = try await js(tab, "location.href = '\(target)'; true")
            progress("assign.end", targetIndex: index)
            progress("handoff-wait.begin", targetIndex: index)
            try await wait { self.externalURLs.count > count && !tab.state.isLoading }
            progress("handoff-wait.end", targetIndex: index)
            // Cross both a renderer timer and browser callback turns, not just the handoff callback.
            progress("timer.begin", targetIndex: index)
            let preserved = try await js(tab, """
                new Promise(resolve => setTimeout(() =>
                  resolve(window.__externalProtocolDocument === 'preserved'), 500))
                """) as? Bool
            progress("timer.end", targetIndex: index)
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
