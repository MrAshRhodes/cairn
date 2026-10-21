import AppKit
import WebKit

/// Owns the original WebKit download, preserving POST bodies, cookies and authentication.
@MainActor
final class WebKitDownload: NSObject, WKDownloadDelegate {
    typealias DestinationPicker = (String, @escaping (URL?) -> Void) -> Void
    private let download: WKDownload
    private let destinationPicker: DestinationPicker?
    private weak var tab: WebKitTab?
    private var onFinish: (() -> Void)?
    private var panel: NSSavePanel?
    private var destinationCompletion: ((URL?) -> Void)?
    private var stagingURL: URL?
    private var destinationURL: URL?
    private var destinationFingerprint: FileFingerprint?
    private var scopedURL: URL?
    private var finished = false

    init(download: WKDownload, tab: WebKitTab, destinationPicker: DestinationPicker? = nil,
         onFinish: @escaping () -> Void) {
        self.download = download
        self.destinationPicker = destinationPicker
        self.tab = tab
        self.onFinish = onFinish
        super.init()
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard !finished, let tab, !tab.isClosed else { completionHandler(nil); return }
        destinationCompletion = completionHandler
        if let destinationPicker {
            destinationPicker(Self.safeFilename(suggestedFilename)) { [weak self] in self?.selectDestination($0) }
            return
        }
        guard let window = tab.webView.window else {
            fail("Download cancelled: a browser window is required to choose a destination.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Download"
        panel.message = response.url?.host.map { "Download from \($0)" } ?? "Choose where to save this download."
        panel.nameFieldStringValue = Self.safeFilename(suggestedFilename)
        panel.canCreateDirectories = true
        self.panel = panel
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, !self.finished else { return }
            self.panel = nil
            self.selectDestination(result == .OK ? panel.url : nil)
        }
    }

    private func selectDestination(_ destination: URL?) {
        guard !finished else { return }
        guard let destination else { cancel(report: true); return }
        guard destination.isFileURL else { fail("Download destination must be a local file."); return }
        destinationURL = destination
        if destination.startAccessingSecurityScopedResource() { scopedURL = destination }
        destinationFingerprint = Self.fingerprint(at: destination)
        // WKDownload requires a nonexistent file. Never delete a user's existing destination first.
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".cairn-\(UUID().uuidString).download")
        stagingURL = staging
        let completion = destinationCompletion
        destinationCompletion = nil
        completion?(staging)
    }

    static func safeFilename(_ suggestion: String) -> String {
        let name = (suggestion as NSString).lastPathComponent
            .components(separatedBy: .controlCharacters).joined()
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return name.isEmpty || name == "." || name == ".." ? "Download" : String(name.prefix(200))
    }

    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard !finished, let stagingURL, let destinationURL else { return }
        do {
            let manager = FileManager.default
            if manager.fileExists(atPath: destinationURL.path) {
                guard let original = destinationFingerprint, original == Self.fingerprint(at: destinationURL) else {
                    fail("Could not save download: the destination changed while downloading. The existing file was not replaced.")
                    return
                }
                _ = try manager.replaceItemAt(destinationURL, withItemAt: stagingURL, options: .usingNewMetadataOnly)
            } else {
                try manager.moveItem(at: stagingURL, to: destinationURL)
            }
            self.stagingURL = nil
            finish()
        } catch {
            fail("Could not save download: \(error.localizedDescription)")
        }
    }

    private struct FileFingerprint: Equatable {
        let inode: UInt64
        let device: UInt64
        let size: UInt64
        let modified: Date
    }

    private static func fingerprint(at url: URL) -> FileFingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return FileFingerprint(inode: inode.uint64Value, device: device.uint64Value,
                               size: size.uint64Value, modified: modified)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        fail("Download failed: \(error.localizedDescription)")
    }

    func cancel(report: Bool) {
        guard !finished else { return }
        if report { tab?.reportError("Download cancelled.") }
        finish(cancelDownload: true)
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        tab?.reportError(message)
        finish()
    }

    private func finish(cancelDownload: Bool = false) {
        guard !finished else { return }
        finished = true
        download.delegate = nil
        panel?.cancel(nil)
        panel = nil
        let completion = destinationCompletion
        destinationCompletion = nil
        completion?(nil)
        let partialFile = stagingURL
        let securityScope = scopedURL
        let cleanup = {
            if let partialFile { try? FileManager.default.removeItem(at: partialFile) }
            securityScope?.stopAccessingSecurityScopedResource()
        }
        if cancelDownload {
            // Wait until WebKit has stopped writing before removing the partial file.
            download.cancel { _ in cleanup() }
        } else {
            cleanup()
        }
        stagingURL = nil
        scopedURL = nil
        let callback = onFinish
        onFinish = nil
        callback?()
    }
}
