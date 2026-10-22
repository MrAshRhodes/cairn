import Foundation

/// Process-level health of a tab, reported through `EngineTabHealthEvents`.
public enum EngineTabHealth: Equatable, Sendable {
    case healthy
    /// The page's renderer stopped answering; the engine terminates it if it does not recover.
    case unresponsive
    /// The renderer crashed, was killed, ran out of memory or could not start.
    case crashed(reason: String, code: Int)
    /// A navigation made no progress for too long. `hint` names likely causes the user can act on.
    case navigationStalled(hint: String)
    /// DevTools-based features (user scripts, Boosts) could not be set up; the page still loads.
    case automationUnavailable
}

@MainActor
public protocol EngineTabHealthEvents: EngineTabEvents {
    func engineTab(_ tab: EngineTab, healthDidChange health: EngineTabHealth)
}

/// How engine start-up ended, derived from the exit code CEF reports when initialization fails.
public enum EngineStartupOutcome: Equatable, Sendable {
    /// Another Cairn process owns the profile; this process should exit quietly with `code`.
    case alreadyRunning(code: Int32)
    case failed(code: Int)

    /// CEF_RESULT_CODE_PROFILE_IN_USE (21) and CEF_RESULT_CODE_NORMAL_EXIT_PROCESS_NOTIFIED (24).
    public init(exitCode: Int) {
        self = [21, 24].contains(exitCode) ? .alreadyRunning(code: Int32(exitCode)) : .failed(code: exitCode)
    }
}

/// Resolves the Chromium data root once so every derived path (root cache, per-Space caches, log) shares one prefix.
/// CEF rejects a per-profile cache path that is not under the symlink-resolved root and silently falls back to an
/// in-memory profile, which loses cookies and storage at every quit.
public enum EngineStorageRoot {
    public static func resolve(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // realpath, not resolvingSymlinksInPath: the latter folds /private/var back into the /var symlink.
        guard let resolved = realpath(url.path, nil) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
}
