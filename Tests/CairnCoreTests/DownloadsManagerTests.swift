import Foundation
import Testing
@testable import CairnCore

private final class ResponseGates: @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [URL: DispatchSemaphore] = [:]
    func add(_ url: URL) -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        lock.lock(); gates[url] = gate; lock.unlock()
        return gate
    }
    func get(_ url: URL) -> DispatchSemaphore? {
        lock.lock(); defer { lock.unlock() }
        return gates[url]
    }
    func remove(_ url: URL) {
        lock.lock(); gates[url] = nil; lock.unlock()
    }
}

private final class DownloadProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    static let chunk = Data(repeating: 0x43, count: 32_768)
    static let chunkCount = 20
    static let gates = ResponseGates()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "downloads.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DispatchQueue.global().async { [self] in
            guard let url = request.url else { return }
            defer { Self.gates.remove(url) }
            if url.path == "/network-error" {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: url.path == "/404" ? 404 : 200,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": String(Self.chunk.count * Self.chunkCount)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for index in 0..<(url.path == "/truncated" ? 1 : Self.chunkCount) {
                if index == 1, let gate = Self.gates.get(url) { _ = gate.wait(timeout: .now() + 5) }
                lock.lock()
                let cancelled = stopped
                lock.unlock()
                if cancelled { return }
                client?.urlProtocol(self, didLoad: Self.chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        lock.lock(); stopped = true; lock.unlock()
        if let url = request.url { Self.gates.get(url)?.signal() }
    }
}

@Suite @MainActor struct DownloadsManagerTests {
    private func manager() -> DownloadsManager {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadProtocol.self]
        return DownloadsManager(configuration: configuration)
    }

    private func noPartialFiles(_ directory: TestDirectory) -> Bool {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
                .allSatisfy { !$0.hasSuffix(".partial") }
        } catch { Issue.record(error); return false }
    }

    @Test func streamsProgressAndPublishesOnlyAfterCompletion() async throws {
        let directory = try TestDirectory()
        let destination = directory.file("chosen.bin")
        let manager = manager()
        let url = URL(string: "https://downloads.test/\(UUID())")!
        let gate = DownloadProtocol.gates.add(url)
        defer { gate.signal() }
        let id = try manager.start(url: url, destination: destination)
        try await eventually { manager.items.first?.progress ?? 0 > 0 }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        gate.signal()
        try await eventually { manager.items.first?.status == .completed }
        let item = try #require(manager.items.first)
        #expect(item.id == id)
        #expect(item.progress == 1)
        #expect(item.destination == destination)
        #expect(try Data(contentsOf: destination) == Data(repeating: 0x43, count: DownloadProtocol.chunk.count * DownloadProtocol.chunkCount))
        #expect(noPartialFiles(directory))
        manager.clearFinished()
        #expect(manager.items.isEmpty)
    }

    @Test func cancellationRemovesPartialAndNeverPublishes() async throws {
        let directory = try TestDirectory()
        let destination = directory.file("cancelled.bin")
        let manager = manager()
        let url = URL(string: "https://downloads.test/\(UUID())")!
        let gate = DownloadProtocol.gates.add(url)
        defer { gate.signal() }
        let id = try manager.start(url: url, destination: destination)
        try await eventually { manager.items.first?.progress ?? 0 > 0 }
        manager.cancel(id)
        #expect(manager.items.first?.status == .cancelled)
        try await eventually { noPartialFiles(directory) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test(arguments: ["404", "network-error", "truncated"])
    func failedRequestsSurfaceErrorAndRemovePartial(path: String) async throws {
        let directory = try TestDirectory()
        let destination = directory.file("failed.bin")
        let manager = manager()
        var reported = false
        manager.onError = { _ in reported = true }
        try manager.start(url: URL(string: "https://downloads.test/\(path)")!, destination: destination)
        try await eventually { manager.items.first?.status == .failed }
        #expect(manager.items.first?.errorMessage?.isEmpty == false)
        #expect(reported)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(noPartialFiles(directory))
    }

    @Test func refusesExistingFilesAndSymlinks() throws {
        let directory = try TestDirectory()
        let destination = directory.file("existing.bin")
        let data = Data("keep me".utf8)
        try data.write(to: destination)
        let manager = manager()
        let source = URL(string: "https://downloads.test/success")!
        #expect(throws: (any Error).self) { try manager.start(url: source, destination: destination) }
        let symlink = directory.file("link.bin")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: destination)
        #expect(throws: (any Error).self) { try manager.start(url: source, destination: symlink) }
        #expect(try Data(contentsOf: destination) == data)
        #expect(noPartialFiles(directory))
    }

    @Test func destinationCreatedDuringDownloadIsNeverOverwritten() async throws {
        let directory = try TestDirectory()
        let destination = directory.file("race.bin")
        let manager = manager()
        let url = URL(string: "https://downloads.test/\(UUID())")!
        let gate = DownloadProtocol.gates.add(url)
        defer { gate.signal() }
        try manager.start(url: url, destination: destination)
        try await eventually { manager.items.first?.progress ?? 0 > 0 }
        let data = Data("created by someone else".utf8)
        try data.write(to: destination)
        gate.signal()
        try await eventually { manager.items.first?.status == .failed }
        #expect(try Data(contentsOf: destination) == data)
        #expect(noPartialFiles(directory))
    }

    @Test func sanitizesSuggestionsAndRejectsUnsafeRequests() throws {
        #expect(DownloadsManager.safeFilename("../../evil.txt") == "evil.txt")
        #expect(DownloadsManager.safeFilename("..\\..\\evil.txt") == "evil.txt")
        #expect(DownloadsManager.safeFilename("..") == "Download")
        #expect(DownloadsManager.safeFilename(".hidden") == "Download")
        #expect(DownloadsManager.safeFilename("report\0:2026.txt") == "report2026.txt")
        #expect(DownloadsManager.safeFilename(String(repeating: "界", count: 200)).utf8.count <= 180)
        let directory = try TestDirectory()
        let manager = manager()
        #expect(throws: (any Error).self) {
            try manager.start(url: URL(string: "file:///etc/hosts")!, destination: directory.file("hosts"))
        }
        #expect(throws: (any Error).self) {
            try manager.start(url: URL(string: "https://downloads.test/success")!, destination: directory.file(".hidden"))
        }
        #expect(manager.items.isEmpty)
    }
}
