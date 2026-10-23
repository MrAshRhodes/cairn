import CairnEngineKit
import Foundation

@MainActor private final class TimerSettled { var value = false }

extension Smoke {
    func reportTimerProbe(_ reply: String?, targetIndex: Int) {
        // Closed vocabulary only: probe output is never copied from the page.
        let parts = reply?.split(separator: ":", omittingEmptySubsequences: false).map(String.init) ?? []
        var line = "CAIRN_SMOKE_EXTERNAL_PROBE t=\(ProcessInfo.processInfo.systemUptime) case=\(targetIndex)"
        if parts.count == 3, parts[0].count == 5, parts[0].allSatisfy({ $0 == "0" || $0 == "1" }) {
            let bits = Array(parts[0])
            let visibility = ["visible", "hidden", "prerender"].contains(parts[1]) ? parts[1] : "other"
            let readyState = ["loading", "interactive", "complete"].contains(parts[2]) ? parts[2] : "other"
            line += " entered=\(bits[0]) armed=\(bits[1]) fired=\(bits[2]) resolved=\(bits[3]) marker=\(bits[4])"
            line += " visibility=\(visibility) readyState=\(readyState)"
        } else {
            line += " reply=unavailable"
        }
        fputs(line + "\n", stderr)
        fflush(stderr)
    }

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
            let timerSettled = TimerSettled()
            let timerProbe = Task { @MainActor in
                // Diagnostic only: observe a still-pending timer from a second evaluation; never settles it.
                try? await Task.sleep(for: .seconds(2))
                if timerSettled.value || Task.isCancelled { return }
                progress("timer.probe.begin", targetIndex: index)
                let reply = try? await self.js(tab, """
                    (() => {
                      const t = window.__externalProtocolTimer || {};
                      const bits = [t.entered, t.armed, t.fired, t.resolved,
                                    window.__externalProtocolDocument === 'preserved']
                        .map(value => value === true ? 1 : 0).join('');
                      return bits + ':' + document.visibilityState + ':' + document.readyState;
                    })()
                    """) as? String
                self.reportTimerProbe(reply, targetIndex: index)
            }
            let preserved: Bool?
            do {
                preserved = try await js(tab, """
                    new Promise(resolve => {
                      const t = window.__externalProtocolTimer = {
                        entered: true, armed: false, fired: false, resolved: false };
                      setTimeout(() => {
                        t.fired = true;
                        resolve(window.__externalProtocolDocument === 'preserved');
                        t.resolved = true;
                      }, 500);
                      t.armed = true;
                    })
                    """) as? Bool
            } catch {
                timerSettled.value = true
                timerProbe.cancel()
                throw error
            }
            timerSettled.value = true
            timerProbe.cancel()
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
