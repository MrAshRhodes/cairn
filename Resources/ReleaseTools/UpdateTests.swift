import Foundation

@main
struct UpdateTests {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let app = root.appendingPathComponent("Fixture.app")
        let executable = app.appendingPathComponent("Contents/MacOS/Cairn")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        // RFC 8032 test-vector public key, not a release key. No private key is used.
        let key = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
        let baseline: [String: Any] = [
            "CFBundleIdentifier": "io.github.mrashrhodes.cairn", "CFBundleVersion": "1",
            "CFBundlePackageType": "APPL", "SUPublicEDKey": key,
            "SUVerifyUpdateBeforeExtraction": true, "SURequireSignedFeed": true,
            "SUSignedFeedFailureExpirationInterval": 0, "SUEnableSystemProfiling": false,
            "SUFeedURL": UpdateController.defaultFeedURL.absoluteString
        ]
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            assertions += 1
        }
        func error(_ info: [String: Any], url: URL = UpdateController.defaultFeedURL) -> String? {
            UpdateConfiguration.error(info: info, bundleURL: app, executableURL: executable, feedURL: url)
        }
        check(error(baseline) == nil, "valid configuration")
        for invalidKey in ["", "@SPARKLE_PUBLIC_ED_KEY@", "not-base64", Data(repeating: 0, count: 32).base64EncodedString(),
                           Data(repeating: 1, count: 31).base64EncodedString(), key + "\n"] {
            var info = baseline
            info["SUPublicEDKey"] = invalidKey
            check(error(info)?.contains("public signing key") == true, "reject invalid key")
        }
        for field in ["SUPublicEDKey", "SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction",
                      "SUSignedFeedFailureExpirationInterval", "SUEnableSystemProfiling",
                      "CFBundleVersion", "SUFeedURL"] {
            var info = baseline
            info.removeValue(forKey: field)
            check(error(info) != nil, "reject missing \(field)")
        }
        for field in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"] {
            var info = baseline
            info[field] = false
            check(error(info) != nil, "reject disabled signature policy")
        }
        var info = baseline
        info["SUSignedFeedFailureExpirationInterval"] = 1728000
        check(error(info) != nil, "reject feed validation expiry")
        info["SUSignedFeedFailureExpirationInterval"] = 0.5
        check(error(info) != nil, "reject fractional feed validation expiry")
        info = baseline
        info["CFBundleVersion"] = "development"
        check(error(info) != nil, "reject nonnumeric build version")
        info = baseline
        info["SUEnableSystemProfiling"] = true
        check(error(info) != nil, "reject profiling")
        for url in ["http://example.com/appcast.xml", "file:///appcast.xml",
                    "https://user:password@example.com/appcast.xml", "https://example.com/#fragment"] {
            check(error(baseline, url: URL(string: url)!) != nil, "reject unsafe feed")
        }
        check(UpdateConfiguration.error(info: baseline, bundleURL: root, executableURL: executable,
                                        feedURL: UpdateController.defaultFeedURL) != nil, "reject non-app")
        check(UpdateConfiguration.error(info: baseline, bundleURL: app, executableURL: nil,
                                        feedURL: UpdateController.defaultFeedURL) != nil, "reject missing executable")
        let unbundled = UpdateController()
        check(unbundled.configurationError != nil, "unbundled controller exposes error")
        unbundled.automaticallyChecks = true
        check(!unbundled.automaticallyChecks, "unconfigured controller never schedules checks")
        print("Passed \(assertions) updater configuration checks; no network or private keys used.")
    }
}
