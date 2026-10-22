import AppKit
import Darwin
import CoreServices
import CairnEngineKit

// Downloads performed by the engine: the page's cookies, authentication, POST body or blob source are
// preserved because Chromium itself transfers the bytes. Cairn chooses the destination and shows state.
extension DownloadsManager {
    /// Asks the user where to save, then lets the engine proceed. `decide` is always called exactly once.
    public func beginEngineDownload(_ request: EngineDownloadRequest, decide: @escaping @MainActor (URL?) -> Void) {
        let suggested = request.suggestedFilename.isEmpty ? request.url?.lastPathComponent : request.suggestedFilename
        destinationChooser(Self.safeFilename(suggested)) { [weak self] destination in
            guard let self else { decide(nil); return }
            guard let destination else { decide(nil); return }
            let source = request.url ?? URL(string: "about:blank")!
            do {
                try Self.validateEngineDestination(destination)
                let id = UUID()
                items.append(DownloadItem(id: id, url: source, filename: destination.lastPathComponent,
                                          destination: destination, engineID: request.id,
                                          totalBytes: request.totalBytes))
                engineItemIDs[request.id] = id
                decide(destination)
            } catch {
                reportFailure(url: source, filename: destination.lastPathComponent, error: error)
                decide(nil)
            }
        }
    }

    /// A user-chosen destination must be a plain file path in an existing directory, never a symbolic link.
    static func validateEngineDestination(_ destination: URL) throws {
        guard destination.isFileURL, !destination.hasDirectoryPath, destination.path.hasPrefix("/"),
              destination.lastPathComponent == safeFilename(destination.lastPathComponent) else {
            throw ServiceError.invalidDownload("Choose a valid local filename.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ServiceError.invalidDownload("The destination folder does not exist.")
        }
        var info = stat()
        if lstat(destination.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFREG {
            throw ServiceError.invalidDownload("The destination is not a regular file.")
        }
    }

    public func applyEngineUpdate(_ update: EngineDownloadUpdate) {
        guard let id = engineItemIDs[update.id], let index = items.firstIndex(where: { $0.id == id }) else { return }
        if update.state.isTerminal { engineItemIDs[update.id] = nil }
        else if !items[index].status.isActive { return }
        items[index].receivedBytes = update.receivedBytes
        if update.totalBytes >= 0 { items[index].totalBytes = update.totalBytes }
        items[index].bytesPerSecond = update.state.isTerminal ? 0 : update.bytesPerSecond
        if update.percentComplete >= 0 { items[index].progress = max(items[index].progress, Double(update.percentComplete) / 100) }
        else if items[index].totalBytes > 0 {
            items[index].progress = max(items[index].progress, Double(update.receivedBytes) / Double(items[index].totalBytes))
        }
        switch update.state {
        case .inProgress: items[index].status = .downloading
        case .paused: items[index].status = .paused
        case .completed:
            items[index].status = .completed
            items[index].progress = 1
            items[index].errorMessage = nil
            if let path = update.path { items[index].destination = URL(fileURLWithPath: path) }
            if let destination = items[index].destination { Self.ensureQuarantine(destination, source: items[index].url) }
        case .cancelled:
            items[index].status = .cancelled
        case .failed(let message):
            items[index].status = .failed
            items[index].errorMessage = message
            onError?(ServiceError.invalidDownload(message))
        }
    }

    public func pause(_ id: UUID) { sendEngineAction(.pause, id) }
    public func resume(_ id: UUID) { sendEngineAction(.resume, id) }

    func cancelEngineDownload(_ id: UUID, engineID: UInt32) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status.isActive else { return }
        engineControl?(.cancel, engineID)
        items[index].status = .cancelled
        items[index].bytesPerSecond = 0
    }

    private func sendEngineAction(_ action: EngineDownloadAction, _ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.status.isActive, let engineID = item.engineID else { return }
        engineControl?(action, engineID)
    }

    /// Chromium normally tags downloads itself; this guarantees Gatekeeper still sees a web origin when it does not.
    static func ensureQuarantine(_ file: URL, source: URL) {
        guard getxattr(file.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) < 0 else { return }
        var properties: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: "Cairn",
        ]
        if URLResolver.isWebURL(source) { properties[kLSQuarantineDataURLKey as String] = source }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var target = file
        do { try target.setResourceValues(values) }
        catch { NSLog("Cairn could not quarantine %@: %@", file.lastPathComponent, error.localizedDescription) }
    }
}
