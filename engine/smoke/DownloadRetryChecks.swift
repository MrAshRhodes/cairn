import AppKit
import CairnEngineKit

@MainActor
final class DownloadRetryProbe: EngineDownloadDelegate {
    let directory: URL
    var requests: [EngineDownloadRequest] = []
    var updates: [UInt32: EngineDownloadUpdate] = [:]
    var destinations: [UInt32: URL] = [:]
    init(_ directory: URL) { self.directory = directory }

    func engineWillStartDownload(_ request: EngineDownloadRequest, decide: @escaping @MainActor (URL?) -> Void) {
        requests.append(request)
        let path = request.suggestedFilename == "retry-blob.bin"
            ? directory.appendingPathComponent("not-a-folder/blob.bin")
            : directory.appendingPathComponent("\(request.id)-\(request.suggestedFilename)")
        destinations[request.id] = path
        decide(path)
    }
    func engineDownloadDidUpdate(_ update: EngineDownloadUpdate) { updates[update.id] = update }
}

extension Smoke {
    private func failedRetryDownload(_ tab: EngineTab, _ selector: String, _ probe: DownloadRetryProbe,
                                     native: Bool = false) async throws -> EngineDownloadRequest {
        let count = probe.requests.count
        if native { try await nativeClick(tab, selector) }
        else { try await scriptClick(tab, selector) }
        if selector == "#blob" {
            try require(try await js(tab, "typeof window.retryBlobURL === 'string' && window.retryBlobURL.startsWith('blob:')") as? Bool == true,
                        "native activation creates the blob download fixture")
        }
        try await wait {
            probe.requests.count == count + 1 && probe.updates[probe.requests[count].id]?.state.isTerminal == true
        }
        let request = probe.requests[count]
        guard case .failed = probe.updates[request.id]?.state else {
            throw SmokeError.failed("Expected interrupted \(selector), got \(String(describing: probe.updates[request.id]))")
        }
        return request
    }

    /// Served by download_retry_fixture.py; the runner explicitly routes /dl-retry/ to that module.
    func checkDownloadRetries() async throws {
        let directory = root.resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent("download-retry", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: directory.appendingPathComponent("not-a-folder"))
        let probe = DownloadRetryProbe(directory)
        engine.downloadDelegate = probe
        defer { engine.downloadDelegate = nil }
        defer { print("RETRY PROBE: requests=\(probe.requests.map(\.id)) updates=\(probe.updates)") }

        let signedIn = make("retry-auth")
        try await load(signedIn, path: "dl-retry/login")
        let request = try await failedRetryDownload(signedIn, "#interrupted", probe)
        try require(request.profileID == "retry-auth" && probe.updates[request.id]?.retry == .available,
                    "interrupted authenticated GET keeps its original Space and retry capability")
        engine.performDownloadAction(.retry(attempt: 1), id: request.id)
        engine.performDownloadAction(.retry(attempt: 1), id: request.id)
        try await wait { probe.updates[request.id]?.attempt == 1 && probe.updates[request.id]?.state.isTerminal == true }
        guard case .failed = probe.updates[request.id]?.state else {
            throw SmokeError.failed("Unarmed retry should still fail")
        }
        try require(probe.updates[request.id]?.retry == .available,
                    "an interrupted retry remains eligible for another explicit attempt")
        try require(probe.requests.count == 1, "retry failure and repeated clicks do not create another job or destination prompt")
        _ = try await js(signedIn, "fetch('/dl-retry/arm', {method:'POST'}).then(r => r.json())")
        engine.performDownloadAction(.retry(attempt: 2), id: request.id)
        try await wait { probe.updates[request.id]?.attempt == 2 && probe.updates[request.id]?.state.isTerminal == true }
        try require(probe.updates[request.id]?.state == .completed,
                    "original Chromium transfer retries successfully after an interrupted response")
        let expected = Data(String(repeating: "Cairn signed-in retry\n", count: 10_000).utf8)
        try require(try Data(contentsOf: probe.destinations[request.id]!) == expected,
                    "retry writes exact authenticated bytes without duplicating the partial")
        try require(try await js(signedIn, """
            fetch('/dl-retry/state').then(r => r.json()).then(s =>
              s.requests.filter(r => r.path === '/dl-retry/interrupted.bin').every(r => r.authenticated && r.method === 'GET'))
            """) as? Bool == true, "every retry request stays in the signed-in engine context")

        let anonymous = make("retry-anonymous")
        try await load(anonymous, path: "dl-retry/anon")
        try await scriptClick(anonymous, "#interrupted")
        try await Task.sleep(for: .milliseconds(500))
        try require(probe.requests.count == 1, "another Space cannot inherit authenticated retry cookies")

        let post = try await failedRetryDownload(signedIn, "#post", probe, native: true)
        try require(probe.updates[post.id]?.retry != .available, "failed POST explains that it must restart from its page")
        let postCount = try await js(signedIn, "fetch('/dl-retry/state').then(r=>r.json()).then(s=>s.requests.filter(r=>r.method==='POST').length)") as? Int
        engine.performDownloadAction(.retry(attempt: 1), id: post.id)
        try await Task.sleep(for: .milliseconds(200))
        let afterPost = try await js(signedIn, "fetch('/dl-retry/state').then(r=>r.json()).then(s=>s.requests.filter(r=>r.method==='POST').length)") as? Int
        try require(postCount == 1 && afterPost == postCount, "even a forced retry action cannot replay the one-use POST")

        let blobTab = make("retry-auth")
        try await load(blobTab, path: "dl-retry/login")
        let blob = try await failedRetryDownload(blobTab, "#blob", probe, native: true)
        _ = try await js(blobTab, "URL.revokeObjectURL(window.retryBlobURL); true")
        engine.performDownloadAction(.retry(attempt: 1), id: blob.id)
        try require(probe.updates[blob.id]?.retry != .available, "expired blob never becomes a URL-only retry")

        let replacementTab = make("retry-auth")
        try await load(replacementTab, path: "dl-retry/login")
        let replaced = try await failedRetryDownload(replacementTab, "#replaced", probe, native: true)
        let destination = probe.destinations[replaced.id]!
        try Data("unrelated file".utf8).write(to: destination, options: .atomic)
        engine.performDownloadAction(.retry(attempt: 1), id: replaced.id)
        try require(probe.updates[replaced.id]?.retry != .available
                    && String(decoding: try Data(contentsOf: destination), as: UTF8.self) == "unrelated file",
                    "retry refuses to overwrite a replaced partial file")

        let closing = make("retry-auth")
        try await load(closing, path: "dl-retry/login")
        let closed = try await failedRetryDownload(closing, "#closed", probe)
        closing.close()
        try await wait { probe.updates[closed.id]?.retry != .available }
        engine.performDownloadAction(.retry(attempt: 1), id: closed.id)
        try require(probe.updates[closed.id]?.retry != .available, "closing the original tab invalidates retry rather than crossing profiles")
    }
}
