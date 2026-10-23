import AppKit
import Observation
import Darwin
import CoreServices
import CairnEngineKit

public struct DownloadItem: Identifiable, Sendable {
    public enum Status: String, Sendable {
        case downloading, paused, completed, cancelled, failed
        /// Still transferring (or resumable): cannot be cleared and has live controls.
        public var isActive: Bool { self == .downloading || self == .paused }
    }
    public var id: UUID
    public var url: URL
    public var filename: String
    public var progress: Double
    public var status: Status
    public var destination: URL?
    public var errorMessage: String?
    /// Set for downloads performed by the engine (with the page's cookies and sign-in). Per-launch id.
    public var engineID: UInt32?
    public var receivedBytes: Int64
    /// -1 when unknown.
    public var totalBytes: Int64
    public var bytesPerSecond: Int64
    public var retry: EngineDownloadRetry = .missingContext
    public var attempt: UInt32 = 0
    public init(id: UUID = UUID(), url: URL, filename: String, progress: Double = 0,
                status: Status = .downloading, destination: URL? = nil, errorMessage: String? = nil,
                engineID: UInt32? = nil, receivedBytes: Int64 = 0, totalBytes: Int64 = -1, bytesPerSecond: Int64 = 0) {
        self.id = id; self.url = url; self.filename = filename; self.progress = progress
        self.status = status; self.destination = destination; self.errorMessage = errorMessage
        self.engineID = engineID; self.receivedBytes = receivedBytes; self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }
}

/// Downloads are explicitly user-directed and never opened automatically.
/// Pasted links use an isolated URL session. Downloads started by a page are performed by the engine itself
/// (see `DownloadsManager+Engine.swift`), so they keep the page's cookies, sign-in, POST body or blob source.
@MainActor @Observable
public final class DownloadsManager {
    public internal(set) var items: [DownloadItem] = []
    @ObservationIgnored public var onError: ((Error) -> Void)?
    @ObservationIgnored private var transfers: [UUID: DownloadTransfer] = [:]
    @ObservationIgnored var engineItemIDs: [UInt32: UUID] = [:]
    /// Sends controls/retry to the original engine; set by the app. Without it engine downloads cannot be controlled.
    @ObservationIgnored public var engineControl: ((EngineDownloadAction, UInt32) -> Void)?
    /// Asks the user for a destination; replaceable so tests do not show a panel.
    @ObservationIgnored public var destinationChooser: (_ suggestedFilename: String, _ completion: @escaping @MainActor (URL?) -> Void) -> Void = DownloadsManager.presentSavePanel
    @ObservationIgnored private let configuration: URLSessionConfiguration

    public convenience init() { self.init(configuration: .ephemeral) }

    /// A custom configuration permits deterministic URLProtocol tests, not shared browser cookie storage.
    public init(configuration: URLSessionConfiguration) {
        let copy = configuration.copy() as! URLSessionConfiguration
        copy.httpCookieStorage = nil
        copy.httpShouldSetCookies = false
        copy.urlCredentialStorage = nil
        copy.urlCache = nil
        copy.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.configuration = copy
    }

    deinit { for transfer in transfers.values { transfer.cancel() } }

    public func start(url: URL, suggestedFilename: String? = nil) {
        guard URLResolver.isWebURL(url) else {
            reportFailure(url: url, filename: Self.safeFilename(suggestedFilename), error: ServiceError.invalidDownload("Only HTTP(S) URLs are supported."))
            return
        }
        destinationChooser(Self.safeFilename(suggestedFilename ?? url.lastPathComponent)) { [weak self] destination in
            guard let self, let destination else { return }
            do { try self.start(url: url, destination: destination) }
            catch { self.reportFailure(url: url, filename: destination.lastPathComponent, error: error) }
        }
    }

    static func presentSavePanel(_ suggestedFilename: String, completion: @escaping @MainActor (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.title = "Save Download"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFilename
        panel.begin { response in
            let url = response == .OK ? panel.url : nil
            Task { @MainActor in completion(url) }
        }
    }

    /// `destination` must come from a user choice. An existing file is rejected, including symbolic links.
    @discardableResult
    public func start(url: URL, destination: URL) throws -> UUID {
        guard URLResolver.isWebURL(url), destination.isFileURL, !destination.hasDirectoryPath,
              destination.path.hasPrefix("/"),
              destination.lastPathComponent == Self.safeFilename(destination.lastPathComponent) else {
            throw ServiceError.invalidDownload("Choose a valid local filename and an HTTP(S) source.")
        }
        let id = UUID()
        let transfer = try DownloadTransfer(url: url, destination: destination, configuration: configuration) { [weak self] event in
            Task { @MainActor in self?.receive(event, for: id) }
        }
        items.append(DownloadItem(id: id, url: url, filename: destination.lastPathComponent, destination: destination))
        transfers[id] = transfer
        transfer.start()
        return id
    }

    public func cancel(_ id: UUID) {
        if let engineID = items.first(where: { $0.id == id })?.engineID { cancelEngineDownload(id, engineID: engineID); return }
        guard let transfer = transfers[id], transfer.cancel(),
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = .cancelled
    }

    public func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.status == .completed,
              let destination = item.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    public func clearFinished() {
        for item in items where !item.status.isActive {
            if let engineID = item.engineID {
                engineItemIDs[engineID] = nil
                engineControl?(.cancel, engineID)
            }
        }
        items.removeAll { !$0.status.isActive }
    }

    /// Server suggestions are labels only, never paths.
    public static func safeFilename(_ suggested: String?) -> String {
        let leaf = (suggested ?? "").replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let cleaned = String(leaf.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != ":" && $0 != "\0"
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != "..", !cleaned.hasPrefix(".") else { return "Download" }
        var filename = String(cleaned.prefix(180))
        while filename.utf8.count > 180 { filename.removeLast() }
        return filename
    }

    private func receive(_ event: DownloadTransfer.Event, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            if event.isTerminal { transfers[id] = nil }
            return
        }
        switch event {
        case .progress(let fraction):
            if items[index].status == .downloading { items[index].progress = max(items[index].progress, fraction) }
        case .finished(let error, let cancelled):
            transfers[id] = nil
            if cancelled || items[index].status == .cancelled {
                items[index].status = .cancelled
            } else if let error {
                items[index].status = .failed
                items[index].errorMessage = error.localizedDescription
                onError?(error)
            } else {
                items[index].status = .completed
                items[index].progress = 1
            }
        }
    }

    func reportFailure(url: URL, filename: String, error: Error) {
        items.append(DownloadItem(url: url, filename: filename, status: .failed, errorMessage: error.localizedDescription))
        onError?(error)
    }
}

// A serial URLSession delegate streams to a same-directory staging file, with bounded memory.
// The lock makes cancellation and the exclusive final publish one atomic decision.
private final class DownloadTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event: @unchecked Sendable {
        case progress(Double)
        case finished(Error?, cancelled: Bool)
        var isTerminal: Bool { if case .finished = self { return true }; return false }
    }

    private let lock = NSLock()
    private let destination: URL
    private let staging: URL
    private let scoped: Bool
    private let callback: @Sendable (Event) -> Void
    private let handle: FileHandle
    private var session: URLSession!
    private var task: URLSessionDataTask!
    private var expectedBytes: Int64 = -1
    private var verifyLength = false
    private var receivedBytes: Int64 = 0
    private var lastProgress: Double = 0
    private var responseError: Error?
    private var cancelled = false
    private var finished = false

    init(url: URL, destination: URL, configuration: URLSessionConfiguration,
         callback: @escaping @Sendable (Event) -> Void) throws {
        self.destination = destination
        self.callback = callback
        scoped = destination.startAccessingSecurityScopedResource()
        staging = destination.deletingLastPathComponent().appendingPathComponent(".cairn-\(UUID().uuidString).partial")
        var info = stat()
        guard lstat(destination.path, &info) != 0, errno == ENOENT else {
            if scoped { destination.stopAccessingSecurityScopedResource() }
            throw ServiceError.invalidDownload("The destination already exists or cannot be inspected. Choose another filename.")
        }
        let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            let reason = String(cString: strerror(errno))
            if scoped { destination.stopAccessingSecurityScopedResource() }
            throw ServiceError.invalidDownload(reason)
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        task = session.dataTask(with: url)
    }

    func start() { task.resume() }

    @discardableResult
    func cancel() -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        cancelled = true
        lock.unlock()
        task.cancel()
        return true
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let accepted: Bool
        if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
           let url = http.url, URLResolver.isWebURL(url) {
            expectedBytes = response.expectedContentLength
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
            verifyLength = expectedBytes >= 0 && (encoding == nil || encoding == "identity")
            accepted = !cancelled
        } else {
            let status = (response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" } ?? "Invalid response"
            responseError = ServiceError.invalidDownload(status)
            accepted = false
        }
        lock.unlock()
        completionHandler(accepted ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, URLResolver.isWebURL(url) else {
            lock.lock()
            responseError = ServiceError.invalidDownload("Unsafe redirect.")
            lock.unlock()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, responseError == nil else { return }
        do {
            try handle.write(contentsOf: data)
            receivedBytes += Int64(data.count)
            if expectedBytes > 0 {
                let progress = min(0.99, Double(receivedBytes) / Double(expectedBytes))
                if progress - lastProgress >= 0.01 {
                    lastProgress = progress
                    callback(.progress(progress))
                }
            }
        } catch {
            responseError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        var failure = responseError ?? error
        if failure == nil, !cancelled, verifyLength, expectedBytes != receivedBytes {
            failure = ServiceError.invalidDownload("The response ended before the declared file length was received.")
        }
        do {
            try handle.synchronize()
            try handle.close()
            if failure == nil, !cancelled {
                // Hard-link publication is atomic and fails with EEXIST; unlike rename it cannot overwrite.
                guard link(staging.path, destination.path) == 0 else {
                    throw ServiceError.invalidDownload(String(cString: strerror(errno)))
                }
            }
        } catch {
            if failure == nil { failure = error }
        }
        if unlink(staging.path) != 0, errno != ENOENT, failure == nil {
            failure = ServiceError.invalidDownload("Unable to remove the partial file: \(String(cString: strerror(errno)))")
        }
        finished = true
        let wasCancelled = cancelled
        lock.unlock()
        if scoped { destination.stopAccessingSecurityScopedResource() }
        session.finishTasksAndInvalidate()
        callback(.finished(failure, cancelled: wasCancelled))
    }
}
