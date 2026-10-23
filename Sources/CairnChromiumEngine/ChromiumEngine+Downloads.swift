import Foundation
import CairnEngineKit
import CairnChromiumBridge

/// Process-wide because Chromium downloads outlive the tab (and Space view) that started them.
@MainActor
final class ChromiumDownloadBridge: NSObject, @preconcurrency CCChromiumDownloadDelegate {
    static let shared = ChromiumDownloadBridge()
    weak var delegate: EngineDownloadDelegate?
    // The bridge only knows a tab's hashed profile directory; the app needs the Space's profile ID back.
    private var profileIDs: [String: String] = [:]

    func remember(profileID: String) { profileIDs[ChromiumEngine.profileDirectory(profileID)] = profileID }

    func chromiumDownloadWillStart(_ info: [String: Any], decide: @escaping (String?) -> Void) {
        let request = EngineDownloadRequest(
            id: (info["id"] as? NSNumber)?.uint32Value ?? 0,
            url: (info["url"] as? String).flatMap(URL.init(string:)),
            suggestedFilename: info["suggestedName"] as? String ?? "",
            mimeType: info["mime"] as? String ?? "",
            totalBytes: (info["totalBytes"] as? NSNumber)?.int64Value ?? -1,
            profileID: (info["profile"] as? String).flatMap { profileIDs[$0] } ?? "",
            isEphemeral: info["ephemeral"] as? Bool ?? false)
        guard let delegate else { decide(nil); return }
        delegate.engineWillStartDownload(request) { url in decide(url?.path) }
    }

    func chromiumDownloadUpdated(_ update: [String: Any]) {
        delegate?.engineDownloadDidUpdate(Self.makeUpdate(update))
    }

    static func makeUpdate(_ value: [String: Any]) -> EngineDownloadUpdate {
        func int(_ key: String) -> Int64 { (value[key] as? NSNumber)?.int64Value ?? 0 }
        func flag(_ key: String) -> Bool { value[key] as? Bool ?? false }
        let state: EngineDownloadState
        if flag("complete") { state = .completed }
        else if flag("canceled") { state = .cancelled }
        else if flag("interrupted") { state = EngineDownloadFailure.state(forInterruptReason: Int(int("reason"))) }
        else if flag("paused") { state = .paused }
        else { state = .inProgress }
        let path = value["path"] as? String
        return EngineDownloadUpdate(
            id: UInt32(truncatingIfNeeded: int("id")), state: state, receivedBytes: int("received"),
            totalBytes: int("total"), percentComplete: Int(int("percent")), bytesPerSecond: int("speed"),
            path: path?.isEmpty == false ? path : nil,
            retry: flag("retryable") ? .available : .unavailable(value["retryReason"] as? String
                ?? "The original download context is unavailable. Start the download again from its page."),
            attempt: UInt32(truncatingIfNeeded: int("attempt")))
    }
}

extension ChromiumEngine: EngineDownloadControlling {
    public var downloadDelegate: EngineDownloadDelegate? {
        get { ChromiumDownloadBridge.shared.delegate }
        set {
            ChromiumDownloadBridge.shared.delegate = newValue
            CCChromiumDownloads.delegate = ChromiumDownloadBridge.shared
        }
    }

    public func performDownloadAction(_ action: EngineDownloadAction, id: UInt32) {
        switch action {
        case .pause: CCChromiumDownloads.pause(id)
        case .resume: CCChromiumDownloads.resume(id)
        case .cancel: CCChromiumDownloads.cancel(id)
        case .retry(let attempt): CCChromiumDownloads.retry(id, attempt: attempt)
        }
    }
}
