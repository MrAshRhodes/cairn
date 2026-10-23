// swift-tools-version:6.0
import PackageDescription
import Foundation

// Chromium (CEF) is the only engine. CEF is single-architecture: it follows the host unless
// CAIRN_CEF_ARCH selects arm64 or x86_64. The manifest must not inspect engine/: SwiftPM caches
// its result by manifest content and environment, not by the files it reads, so a missing CEF is
// reported by the #error guards at the top of the C++ sources (pins are verified by engine/tool.py).
#if arch(arm64)
let hostArchitecture = "arm64"
#else
let hostArchitecture = "x86_64"
#endif
let engineArchitecture = ProcessInfo.processInfo.environment["CAIRN_CEF_ARCH"] ?? hostArchitecture
precondition(
    ["arm64", "x86_64"].contains(engineArchitecture),
    "CAIRN_CEF_ARCH must be arm64 or x86_64 (CEF builds are single-architecture), got \"\(engineArchitecture)\"."
)
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let cef = "\(root)/engine/cef/\(engineArchitecture)"
let cefBuild = "\(root)/engine/.cache/build-\(engineArchitecture)"
let cppSettings: [CXXSetting] = [
    .unsafeFlags(["-I\(cef)", "-I\(cefBuild)", "-fno-rtti"]),
    .define("CEF_USE_SANDBOX"), .define("CEF_API_VERSION", to: "15400"),
]
let cefLinkSettings: [LinkerSetting] = [
    .unsafeFlags(["\(cefBuild)/libcef_dll_wrapper/libcef_dll_wrapper.a"]),
    .linkedFramework("AppKit"), .linkedFramework("IOSurface"), .linkedLibrary("c++"),
]

let package = Package(
    name: "Cairn",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Cairn", targets: ["Cairn"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(name: "CairnEngineKit"),
        .target(name: "CairnCore", dependencies: ["CairnEngineKit"], resources: [.copy("Resources/PublicSuffix")]),
        .target(name: "CairnModules", dependencies: ["CairnCore", "CairnEngineKit"]),
        .target(name: "CairnBoosts", dependencies: ["CairnCore", "CairnEngineKit"]),
        .target(name: "CairnImport", dependencies: ["CairnCore"]),
        .target(name: "CairnChromiumBridge", publicHeadersPath: "include",
                cxxSettings: cppSettings + [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: cefLinkSettings),
        .target(name: "CairnChromiumEngine", dependencies: ["CairnChromiumBridge", "CairnEngineKit"]),
        .target(name: "CairnUpdater", dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
        .target(name: "CairnUI", dependencies: [
            "CairnCore", "CairnEngineKit", "CairnModules", "CairnBoosts", "CairnUpdater", "CairnImport",
        ]),
        .executableTarget(name: "Cairn", dependencies: [
            "CairnUI", "CairnCore", "CairnEngineKit", "CairnModules", "CairnBoosts", "CairnChromiumEngine", "CairnUpdater",
        ]),
        .executableTarget(name: "CairnHelper", cxxSettings: cppSettings, linkerSettings: cefLinkSettings),
        .executableTarget(name: "CairnChromiumSmoke",
                          dependencies: ["CairnChromiumEngine", "CairnEngineKit", "CairnBoosts"],
                          path: "engine/smoke"),
        .testTarget(name: "CairnCoreTests", dependencies: ["CairnCore", "CairnEngineKit"], exclude: ["Fixtures"]),
        .testTarget(name: "CairnModulesTests", dependencies: ["CairnModules", "CairnBoosts", "CairnCore", "CairnEngineKit"]),
        .testTarget(name: "CairnImportTests", dependencies: ["CairnImport", "CairnCore"]),
        .testTarget(name: "CairnUITests", dependencies: ["CairnUI", "CairnCore", "CairnEngineKit"]),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx20
)
