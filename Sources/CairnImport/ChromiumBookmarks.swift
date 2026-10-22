import Foundation

/// Parses a Chromium `Bookmarks` JSON document (Chrome, Edge, Brave, Vivaldi, Opera).
public enum ChromiumBookmarks {
    public struct Result: Sendable {
        public var bookmarks: [ImportedBookmark]
        public var skipped: SkipCounts
    }

    private static let rootNames = ["bookmark_bar": nil, "other": "Other Bookmarks", "synced": "Mobile Bookmarks"] as [String: String?]

    public static func parse(_ data: Data) throws -> Result {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = object["roots"] as? [String: Any] else {
            throw ImportError.malformed("Expected a Chromium Bookmarks file with a \"roots\" section.")
        }
        var parsed = ParsedBookmarks()
        for key in ["bookmark_bar", "other", "synced"] {
            guard let root = roots[key] as? [String: Any] else { continue }
            let prefix = (rootNames[key] ?? nil).map { [$0] } ?? []
            walk(root, path: prefix, into: &parsed, depth: 0)
        }
        return Result(bookmarks: parsed.bookmarks, skipped: parsed.skipped)
    }

    private static func walk(_ node: [String: Any], path: [String], into parsed: inout ParsedBookmarks, depth: Int) {
        guard depth < 64 else { return }
        switch node["type"] as? String {
        case "url":
            parsed.add(title: node["name"] as? String ?? "", address: node["url"] as? String ?? "", folderPath: path)
        case "folder":
            let name = node["name"] as? String ?? ""
            // The root folders themselves are not part of the user's folder path.
            let childPath = depth == 0 ? path : path + [name]
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child, path: childPath, into: &parsed, depth: depth + 1) }
        default:
            break
        }
    }
}
