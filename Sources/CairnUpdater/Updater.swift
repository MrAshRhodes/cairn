import Foundation
import Sparkle

// STUB — replaced by the UPDATE agent (Sparkle wrapper: check now, automatic checks, feed URL, channel).
public enum UpdaterModule {
    public static var controllerType: AnyClass { SPUStandardUpdaterController.self }
}

@MainActor
public final class UpdateController {
    nonisolated public static let defaultFeedURL = URL(string: "https://github.com/mrashrhodes/cairn/releases/latest/download/appcast.xml")!
    public var automaticallyChecks = false
    public private(set) var configurationError: String? = "Updates are not configured."
    public init(feedURL: URL = UpdateController.defaultFeedURL) {}
    public func checkForUpdates() {}
}
