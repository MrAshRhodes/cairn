// swift-tools-version:6.0
import PackageDescription
import Foundation

// The default build never needs Chromium. Opt in with: CAIRN_WITH_CHROMIUM=1 scripts/swiftw build
let withChromium = ProcessInfo.processInfo.environment["CAIRN_WITH_CHROMIUM"] == "1"

var extraTargets: [Target] = []
var appDependencies: [Target.Dependency] = [
    "CairnUI", "CairnCore", "CairnEngineKit", "CairnModules", "CairnBoosts", "CairnWebKitEngine", "CairnUpdater",
]
var appSwiftSettings: [SwiftSetting] = []

// >>> CHROMIUM-BEGIN (owned by the engine-cef agent; everything here MUST stay gated by `withChromium`)
if withChromium {
    #if arch(arm64)
    let hostArchitecture = "arm64"
    #else
    let hostArchitecture = "x86_64"
    #endif
    let engineArchitecture = ProcessInfo.processInfo.environment["CAIRN_CEF_ARCH"] ?? hostArchitecture
    precondition(["arm64", "x86_64"].contains(engineArchitecture), "CEF supports single-architecture arm64 or x86_64 builds.")
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
    let cef = "\(root)/engine/cef/\(engineArchitecture)"
    let wrapper = "\(root)/engine/.cache/build-\(engineArchitecture)/libcef_dll_wrapper/libcef_dll_wrapper.a"
    func chromiumJSON(_ path: String) -> NSDictionary? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
    }
    let artifacts = chromiumJSON("\(root)/engine/cef.lock.json")?["artifacts"] as? NSDictionary
    guard let pin = artifacts?[engineArchitecture] as? NSDictionary,
          let downloaded = chromiumJSON("\(cef)/.cairn-pin.json"),
          let built = chromiumJSON("\(root)/engine/.cache/build-\(engineArchitecture)/.cairn-pin.json"),
          downloaded.isEqual(pin), built.isEqual(pin),
          FileManager.default.fileExists(atPath: wrapper) else {
        fatalError("Missing/stale CEF: run python3 engine/tool.py fetch && python3 engine/tool.py build (with --arch \(engineArchitecture)) first.")
    }
    let cppSettings: [CXXSetting] = [
        .unsafeFlags(["-I\(cef)", "-fno-rtti"]), .define("CEF_USE_SANDBOX"), .define("CEF_API_VERSION", to: "15400"),
    ]
    let cefLinkSettings: [LinkerSetting] = [
        .unsafeFlags([wrapper]), .linkedFramework("AppKit"),
        .linkedFramework("IOSurface"), .linkedLibrary("c++"),
    ]
    extraTargets += [
        .target(name: "CairnChromiumBridge", publicHeadersPath: "include",
                cxxSettings: cppSettings + [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: cefLinkSettings),
        .target(name: "CairnChromiumEngine", dependencies: ["CairnChromiumBridge", "CairnEngineKit"]),
        .executableTarget(name: "CairnHelper", cxxSettings: cppSettings, linkerSettings: cefLinkSettings),
        .executableTarget(name: "CairnChromiumSmoke",
                          dependencies: ["CairnChromiumEngine", "CairnEngineKit"],
                          path: "engine/smoke"),
    ]
    appDependencies.append("CairnChromiumEngine")
    appSwiftSettings.append(.define("CAIRN_CHROMIUM"))
}
// <<< CHROMIUM-END

let package = Package(
    name: "Cairn",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Cairn", targets: ["Cairn"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(name: "CairnEngineKit"),
        .target(name: "CairnCore", dependencies: ["CairnEngineKit"]),
        .target(name: "CairnModules", dependencies: ["CairnCore", "CairnEngineKit"]),
        .target(name: "CairnBoosts", dependencies: ["CairnCore", "CairnEngineKit"]),
        .target(name: "CairnWebKitEngine", dependencies: ["CairnEngineKit"]),
        .target(name: "CairnUpdater", dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
        .target(name: "CairnUI", dependencies: [
            "CairnCore", "CairnEngineKit", "CairnModules", "CairnBoosts", "CairnUpdater",
        ]),
        .executableTarget(name: "Cairn", dependencies: appDependencies, swiftSettings: appSwiftSettings),
        .testTarget(name: "CairnCoreTests", dependencies: ["CairnCore", "CairnEngineKit"]),
        .testTarget(name: "CairnModulesTests", dependencies: ["CairnModules", "CairnBoosts", "CairnCore", "CairnEngineKit"]),
        .testTarget(name: "CairnWebKitEngineTests", dependencies: ["CairnWebKitEngine", "CairnEngineKit"]),
        .testTarget(name: "CairnUITests", dependencies: ["CairnUI", "CairnCore", "CairnEngineKit"]),
    ] + extraTargets,
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: withChromium ? .cxx20 : nil
)
