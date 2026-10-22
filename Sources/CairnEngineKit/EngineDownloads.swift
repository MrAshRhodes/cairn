import Foundation

// In-engine downloads. The engine performs the transfer (so cookies, authentication, POST bodies and
// blob:/data: sources all work); the app only chooses the destination and shows progress. Downloads
// outlive their tab, so they are reported by the engine rather than through `EngineTabDelegate`.

/// A download the engine is about to start. `id` is a per-launch counter: never persist it.
public struct EngineDownloadRequest: Sendable, Equatable {
    public var id: UInt32
    public var url: URL?
    public var suggestedFilename: String
    public var mimeType: String
    /// -1 when the server did not declare a length.
    public var totalBytes: Int64
    /// The profile (Space) of the tab that started the download.
    public var profileID: String
    public var isEphemeral: Bool
    public init(id: UInt32, url: URL?, suggestedFilename: String, mimeType: String = "",
                totalBytes: Int64 = -1, profileID: String, isEphemeral: Bool = false) {
        self.id = id; self.url = url; self.suggestedFilename = suggestedFilename; self.mimeType = mimeType
        self.totalBytes = totalBytes; self.profileID = profileID; self.isEphemeral = isEphemeral
    }
}

public enum EngineDownloadState: Sendable, Equatable {
    case inProgress
    case paused
    case completed
    /// The user (or the app) cancelled. This is not a failure.
    case cancelled
    case failed(String)

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed: true
        case .inProgress, .paused: false
        }
    }
}

public struct EngineDownloadUpdate: Sendable, Equatable {
    public var id: UInt32
    public var state: EngineDownloadState
    public var receivedBytes: Int64
    /// -1 when unknown.
    public var totalBytes: Int64
    /// 0...100, or -1 when unknown.
    public var percentComplete: Int
    public var bytesPerSecond: Int64
    public var path: String?
    public init(id: UInt32, state: EngineDownloadState, receivedBytes: Int64 = 0, totalBytes: Int64 = -1,
                percentComplete: Int = -1, bytesPerSecond: Int64 = 0, path: String? = nil) {
        self.id = id; self.state = state; self.receivedBytes = receivedBytes; self.totalBytes = totalBytes
        self.percentComplete = percentComplete; self.bytesPerSecond = bytesPerSecond; self.path = path
    }
}

public enum EngineDownloadAction: Sendable { case pause, resume, cancel }

@MainActor
public protocol EngineDownloadDelegate: AnyObject {
    /// Ask where to save. Call `decide` exactly once: a file URL to proceed, or nil to cancel the
    /// download. It may be called later (for example after a save panel).
    func engineWillStartDownload(_ request: EngineDownloadRequest, decide: @escaping @MainActor (URL?) -> Void)
    /// Progress is throttled; every terminal state and pause/resume change is always delivered.
    func engineDownloadDidUpdate(_ update: EngineDownloadUpdate)
}

/// Optional capability of a `BrowserEngine`. `BrowserModel` installs itself as the delegate.
@MainActor
public protocol EngineDownloadControlling: AnyObject {
    var downloadDelegate: EngineDownloadDelegate? { get set }
    func performDownloadAction(_ action: EngineDownloadAction, id: UInt32)
}

/// Maps Chromium's interrupt reasons (`download_interrupt_reasons.h`) to what a person can act on.
public enum EngineDownloadFailure {
    public static let userCanceledReasons: Set<Int> = [40, 41]

    public static func message(forInterruptReason reason: Int) -> String {
        switch reason {
        case 1: "The file could not be written."
        case 2: "Access to the destination was denied."
        case 3: "There is not enough disk space."
        case 5: "The filename is too long."
        case 6: "The file is too large for this volume."
        case 7: "The file was blocked because it contains a virus."
        case 10: "A temporary file error occurred."
        case 11, 12: "The file was blocked by a security check."
        case 13: "The file ended before its expected length."
        case 14: "The file did not match its checksum."
        case 15: "The destination is the same as the source."
        case 20: "The network connection failed."
        case 21: "The network connection timed out."
        case 22: "The network connection was lost."
        case 23: "The server is down."
        case 24: "The request was rejected."
        case 30: "The server could not complete the download."
        case 31: "The server does not support resuming."
        case 33: "The server returned unexpected content."
        case 34: "The website requires you to sign in."
        case 35: "The server's certificate is not trusted."
        case 36: "The website forbids this download."
        case 37: "The server is unreachable."
        case 38: "The server's content length did not match."
        case 39: "The download was redirected to another site."
        case 50: "The browser crashed during the download."
        default: "The download was interrupted (reason \(reason))."
        }
    }

    public static func state(forInterruptReason reason: Int) -> EngineDownloadState {
        userCanceledReasons.contains(reason) ? .cancelled : .failed(message(forInterruptReason: reason))
    }
}
