import AppKit
import Combine
import CryptoKit
import Sparkle

public enum UpdaterModule {
    public static var controllerType: AnyClass { SPUStandardUpdaterController.self }
}

@MainActor
public final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    nonisolated public static let defaultFeedURL = URL(string: "https://github.com/mrashrhodes/cairn/releases/latest/download/appcast.xml")!
    @Published public private(set) var configurationError: String?
    private let feedURL: URL
    private var controller: SPUStandardUpdaterController?

    public var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            guard let controller else { return }
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    public init(feedURL: URL = UpdateController.defaultFeedURL) {
        self.feedURL = feedURL
        super.init()
        let bundle = Bundle.main
        configurationError = UpdateConfiguration.error(
            info: bundle.infoDictionary ?? [:], bundleURL: bundle.bundleURL,
            executableURL: bundle.executableURL, feedURL: feedURL
        )
        guard configurationError == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
        )
        // Never send Sparkle's optional system profile, including from older saved preferences.
        controller.updater.sendsSystemProfile = false
        controller.updater.clearFeedURLFromUserDefaults()
        do {
            try controller.updater.start()
            self.controller = controller
        } catch {
            configurationError = "Updates are unavailable: \(error.localizedDescription)"
        }
    }

    public func checkForUpdates() {
        if let configurationError {
            showError(configurationError)
        } else if let controller, controller.updater.canCheckForUpdates {
            controller.checkForUpdates(nil)
        } else {
            showError("An update check is already in progress. Finish the current check and try again.")
        }
    }

    public func feedURLString(for updater: SPUUpdater) -> String? {
        feedURL.absoluteString
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Cairn Updates Unavailable"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// Separate validation allows testing the fail-closed path without starting AppKit or networking.
enum UpdateConfiguration {
    static func error(info: [String: Any], bundleURL: URL, executableURL: URL?, feedURL: URL) -> String? {
        guard bundleURL.pathExtension == "app",
              info["CFBundlePackageType"] as? String == "APPL",
              let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty,
              let version = info["CFBundleVersion"] as? String,
              version.range(of: #"^[0-9]+(\.[0-9]+){0,2}$"#, options: .regularExpression) != nil,
              let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return "Updates require a complete Cairn.app bundle. Build or install the app instead of running the Swift executable."
        }
        guard let encoded = info["SUPublicEDKey"] as? String,
              let key = Data(base64Encoded: encoded), key.count == 32,
              key.base64EncodedString() == encoded, key.contains(where: { $0 != 0 }),
              (try? Curve25519.Signing.PublicKey(rawRepresentation: key)) != nil else {
            return "This build has no valid Sparkle public signing key. Automatic updates are disabled. Rebuild with SPARKLE_PUBLIC_ED_KEY or install an authenticated release."
        }
        guard info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SURequireSignedFeed"] as? Bool == true,
              (info["SUSignedFeedFailureExpirationInterval"] as? NSNumber)?.doubleValue == 0 else {
            return "This build does not require authenticated update archives and feeds. Updates have been disabled."
        }
        guard info["SUEnableSystemProfiling"] as? Bool == false else {
            return "This build has an invalid update privacy configuration. Updates have been disabled."
        }
        guard isHTTPS(feedURL),
              let configured = info["SUFeedURL"] as? String,
              let configuredURL = URL(string: configured), isHTTPS(configuredURL) else {
            return "The update feed must be an HTTPS URL without embedded credentials. Updates have been disabled."
        }
        return nil
    }

    private static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false &&
            url.user == nil && url.password == nil && url.fragment == nil
    }
}
