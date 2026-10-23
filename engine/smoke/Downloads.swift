import AppKit
import CairnEngineKit

// In-engine download scenarios (served by the fixture routes under /dl/ in engine/smoke.py).
@MainActor final class DownloadProbe: EngineDownloadDelegate {
    let directory: URL
    var requests: [EngineDownloadRequest] = []
    var updates: [UInt32: [EngineDownloadUpdate]] = [:]
    var destinations: [UInt32: URL] = [:]
    init(directory: URL) { self.directory = directory }

    func engineWillStartDownload(_ request: EngineDownloadRequest, decide: @escaping @MainActor (URL?) -> Void) {
        requests.append(request)
        let destination = directory.appendingPathComponent("\(request.id)-\(request.suggestedFilename)")
        destinations[request.id] = destination
        decide(destination)
    }
    func engineDownloadDidUpdate(_ update: EngineDownloadUpdate) { updates[update.id, default: []].append(update) }
    var summary: String { "requests=\(requests.map(\.id)) last=\(updates.mapValues { $0.last.map { "\($0.state) \($0.receivedBytes)" } ?? "-" })" }
    func last(_ id: UInt32) -> EngineDownloadUpdate? { updates[id]?.last }
}

extension Smoke {
    func scriptClick(_ tab: EngineTab, _ selector: String) async throws {
        _ = try await js(tab, "document.querySelector('\(selector)').click(); true")
    }

    /// A real mouse click gives the page user activation, which programmatic `click()` from DevTools lacks.
    func nativeClick(_ tab: EngineTab, _ selector: String) async throws {
        let script = "(() => { const r = document.querySelector('\(selector)').getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()"
        guard let rect = try await js(tab, script) as? [Double], rect.count == 2, let window = tab.view.window else {
            throw SmokeError.failed("No click target \(selector)")
        }
        window.makeKeyAndOrderFront(nil)
        let point = tab.view.convert(NSPoint(x: rect[0], y: tab.view.bounds.height - rect[1]), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            window.sendEvent(event)
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func checkDownloads() async throws {
        guard let root = ProcessInfo.processInfo.environment["CAIRN_SMOKE_DATA_ROOT"] else { throw SmokeError.failed("Missing data root") }
        let directory = URL(fileURLWithPath: root).deletingLastPathComponent().appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let probe = DownloadProbe(directory: directory)
        engine.downloadDelegate = probe
        defer { engine.downloadDelegate = nil }
        defer { print("DOWNLOAD PROBE: \(probe.summary)") }
        let secret = Data(repeating: 0x53, count: 200_000)

        // A cookie-gated attachment: the session cookie is HttpOnly, so only the engine can carry it.
        let signedIn = make("downloads-auth")
        try await load(signedIn, path: "dl/login")
        try await scriptClick(signedIn, "#secret")
        try await wait { probe.requests.count == 1 && probe.last(probe.requests[0].id)?.state.isTerminal == true }
        var request = probe.requests[0]
        try require(request.suggestedFilename == "secret.bin" && request.profileID == "downloads-auth",
                    "Content-Disposition filename and originating Space reach the app")
        try require(probe.last(request.id)?.state == .completed, "cookie-gated download completes in the engine")
        try require(try Data(contentsOf: probe.destinations[request.id]!) == secret, "cookie-gated download delivers the exact bytes")
        try require(probe.last(request.id)?.path == probe.destinations[request.id]!.path, "completed download reports its final path")

        // Another Space has no cookie, so the server refuses and nothing is downloaded.
        let signedOut = make("downloads-anon")
        try await load(signedOut, path: "dl/anon")
        try await scriptClick(signedOut, "#secret")
        try await Task.sleep(for: .milliseconds(1500))
        try require(probe.requests.count == 1, "another Space does not inherit the download cookie")

        // POST body download.
        let post = make("downloads-auth")
        try await load(post, path: "dl/login")
        try await scriptClick(post, "#post")
        try await wait { probe.requests.count == 2 && probe.last(probe.requests[1].id)?.state.isTerminal == true }
        request = probe.requests[1]
        try require(probe.last(request.id)?.state == .completed
                    && String(decoding: try Data(contentsOf: probe.destinations[request.id]!), as: UTF8.self) == "posted=cairn",
                    "POST download keeps its request body")

        // blob: download created by the page.
        let blob = make("downloads-auth")
        try await load(blob, path: "dl/login")
        try await nativeClick(blob, "#blob")
        try await wait { probe.requests.count == 3 && probe.last(probe.requests[2].id)?.state.isTerminal == true }
        request = probe.requests[2]
        try require(request.suggestedFilename == "blob.txt" && probe.last(request.id)?.state == .completed
                    && String(decoding: try Data(contentsOf: probe.destinations[request.id]!), as: UTF8.self) == "blob-bytes",
                    "blob: download completes")

        // Pause and resume a slow download.
        let slow = make("downloads-auth")
        try await load(slow, path: "dl/login")
        try await scriptClick(slow, "#slow")
        try await wait { probe.requests.count == 4 && (probe.last(probe.requests[3].id)?.receivedBytes ?? 0) > 0 }
        request = probe.requests[3]
        engine.performDownloadAction(.pause, id: request.id)
        try await wait { probe.last(request.id)?.state == .paused }
        try require(true, "download pauses")
        engine.performDownloadAction(.resume, id: request.id)
        try await wait { probe.last(request.id)?.state.isTerminal == true }
        try require(probe.last(request.id)?.state == .completed
                    && (try Data(contentsOf: probe.destinations[request.id]!)).count == 400_000, "download resumes and completes")

        // User cancellation is not a failure and leaves no file.
        let cancel = make("downloads-auth")
        try await load(cancel, path: "dl/login")
        try await scriptClick(cancel, "#slow")
        try await wait { probe.requests.count == 5 && (probe.last(probe.requests[4].id)?.receivedBytes ?? 0) > 0 }
        request = probe.requests[4]
        engine.performDownloadAction(.cancel, id: request.id)
        try await wait { probe.last(request.id)?.state.isTerminal == true }
        try require(probe.last(request.id)?.state == .cancelled, "cancelled download reports cancellation, not failure")
        try require(!FileManager.default.fileExists(atPath: probe.destinations[request.id]!.path), "cancelled download leaves no file")

        // A server that drops the connection is a failure with a reason.
        let broken = make("downloads-auth")
        try await load(broken, path: "dl/login")
        try await scriptClick(broken, "#truncated")
        try await wait { probe.requests.count >= 6 && probe.last(probe.requests[5].id)?.state.isTerminal == true }
        request = probe.requests[5]
        try require(probe.requests.count == 6, "auto-resume does not ask for a destination twice")
        if case .failed(let reason) = probe.last(request.id)?.state {
            try require(!reason.isEmpty, "interrupted download reports a failure reason")
        } else {
            throw SmokeError.failed("Truncated download should fail, got \(String(describing: probe.last(request.id)?.state))")
        }
    }
}
