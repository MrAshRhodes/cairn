import Foundation

public enum ImportFormat: Hashable, Sendable {
    case chromiumProfile
    case firefoxProfile
    case firefoxProfiles
    case safariFolder
    case safariBookmarks
    case netscapeHTML
    case cairnJSON
}

/// A place data can be imported from. Discovery only checks that locations exist; it never opens files.
public struct ImportSource: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var browser: String
    public var format: ImportFormat
    public var location: URL
    public var supportsHistory: Bool {
        format == .chromiumProfile || format == .firefoxProfile || format == .safariFolder || format == .cairnJSON
    }
    public var isSafari: Bool { format == .safariFolder || format == .safariBookmarks || browser == "Safari" }

    public init(id: String, name: String, browser: String, format: ImportFormat, location: URL) {
        self.id = id; self.name = name; self.browser = browser; self.format = format; self.location = location
    }
}

public enum ImportSourceDiscovery {
    struct Browser {
        let name: String
        let relativePath: String
    }

    static let chromiumBrowsers = [
        Browser(name: "Google Chrome", relativePath: "Google/Chrome"),
        Browser(name: "Chromium", relativePath: "Chromium"),
        Browser(name: "Microsoft Edge", relativePath: "Microsoft Edge"),
        Browser(name: "Brave", relativePath: "BraveSoftware/Brave-Browser"),
        Browser(name: "Vivaldi", relativePath: "Vivaldi"),
        Browser(name: "Opera", relativePath: "com.operasoftware.Opera"),
        Browser(name: "Arc", relativePath: "Arc/User Data"),
    ]
    /// Chromium profile folders are probed by name so that no directory has to be listed before consent.
    static let profileNames = ["Default"] + (1...9).map { "Profile \($0)" }

    /// Lists installed browsers whose profile folders exist. Uses `exists` only.
    public static func discover(fileSystem: ImportFileSystem = LocalImportFileSystem(),
                                applicationSupport: URL? = nil) -> [ImportSource] {
        let base = applicationSupport ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var sources: [ImportSource] = []
        for browser in chromiumBrowsers {
            let root = base.appendingPathComponent(browser.relativePath, isDirectory: true)
            guard fileSystem.exists(root) else { continue }
            for profile in profileNames {
                let location = root.appendingPathComponent(profile, isDirectory: true)
                guard fileSystem.exists(location) else { continue }
                sources.append(ImportSource(id: "\(browser.name)/\(profile)", name: "\(browser.name) — \(profile)",
                                            browser: browser.name, format: .chromiumProfile, location: location))
            }
        }
        let firefox = base.appendingPathComponent("Firefox/Profiles", isDirectory: true)
        if fileSystem.exists(firefox) {
            sources.append(ImportSource(id: "Firefox", name: "Firefox — Choose Profile…", browser: "Firefox",
                                        format: .firefoxProfiles, location: firefox))
        }
        return sources
    }

    /// Describes a selection using only metadata and known filenames; no file contents are opened.
    public static func chosen(_ url: URL, fileSystem: ImportFileSystem = LocalImportFileSystem()) throws -> ImportSource {
        if fileSystem.isDirectory(url) {
            if fileSystem.exists(url.appendingPathComponent("Bookmarks.plist")) || fileSystem.exists(url.appendingPathComponent("History.db")) {
                return ImportSource(id: "safari:\(url.path)", name: "Safari — \(url.lastPathComponent)", browser: "Safari",
                                    format: .safariFolder, location: url)
            }
            if fileSystem.exists(url.appendingPathComponent("places.sqlite")) {
                return ImportSource(id: "firefox:\(url.path)", name: "Firefox — \(url.lastPathComponent)", browser: "Firefox",
                                    format: .firefoxProfile, location: url)
            }
            if fileSystem.exists(url.appendingPathComponent("Bookmarks")) || fileSystem.exists(url.appendingPathComponent("History")) {
                return ImportSource(id: "folder:\(url.path)", name: url.lastPathComponent, browser: "Chromium-based browser",
                                    format: .chromiumProfile, location: url)
            }
            throw ImportError.unsupportedSource("No supported browser data was found in this folder. Choose an exported bookmarks HTML or cairn-import-v1 JSON file inside it instead.")
        }
        if url.lastPathComponent == "Bookmarks.plist" {
            return ImportSource(id: "safari:\(url.path)", name: "Safari — Bookmarks.plist", browser: "Safari",
                                format: .safariBookmarks, location: url)
        }
        switch url.pathExtension.lowercased() {
        case "html", "htm":
            return ImportSource(id: "file:\(url.path)", name: url.lastPathComponent, browser: "Bookmarks file",
                                format: .netscapeHTML, location: url)
        case "json":
            return ImportSource(id: "file:\(url.path)", name: url.lastPathComponent, browser: "Cairn import file",
                                format: .cairnJSON, location: url)
        default:
            throw ImportError.unsupportedSource("Choose a bookmarks .html export, a cairn-import-v1 .json file, Safari Bookmarks.plist, or a supported browser data folder.")
        }
    }

    /// An explicit Safari folder choice must not silently become another browser or an empty import
    /// when macOS denies metadata access. The consented scan will report any read failure.
    public static func safariFolder(_ url: URL) -> ImportSource {
        ImportSource(id: "safari:\(url.path)", name: "Safari — \(url.lastPathComponent)", browser: "Safari",
                     format: .safariFolder, location: url)
    }
}
