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
    // Add CairnChromiumBridge (ObjC++/CEF), CairnChromiumEngine (Swift) and CairnHelper (C++ helper) to
    // `extraTargets`, append "CairnChromiumEngine" to `appDependencies`, and .define("CAIRN_CHROMIUM") to `appSwiftSettings`.
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
    swiftLanguageModes: [.v5]
)
