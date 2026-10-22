import Foundation

public enum ImportFormat: Hashable, Sendable {
    case chromiumProfile
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
    public var supportsHistory: Bool { format == .chromiumProfile || format == .cairnJSON }

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
        return sources
    }

    /// Describes a file or folder the user picked. Only the extension and `isDirectory` are consulted.
    public static func chosen(_ url: URL, fileSystem: ImportFileSystem = LocalImportFileSystem()) throws -> ImportSource {
        if fileSystem.isDirectory(url) {
            return ImportSource(id: "folder:\(url.path)", name: url.lastPathComponent, browser: "Chromium-based browser",
                                format: .chromiumProfile, location: url)
        }
        switch url.pathExtension.lowercased() {
        case "html", "htm":
            return ImportSource(id: "file:\(url.path)", name: url.lastPathComponent, browser: "Bookmarks file",
                                format: .netscapeHTML, location: url)
        case "json":
            return ImportSource(id: "file:\(url.path)", name: url.lastPathComponent, browser: "Cairn import file",
                                format: .cairnJSON, location: url)
        default:
            throw ImportError.unsupportedSource("Choose a bookmarks .html export, a cairn-import-v1 .json file, or a browser profile folder.")
        }
    }
}
