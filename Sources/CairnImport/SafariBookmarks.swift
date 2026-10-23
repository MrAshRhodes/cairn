import Foundation

/// The bookmark property-list structure also consumed by the open-source Chromium Safari importer.
public enum SafariBookmarks {
    public static let accessGuidance = "macOS may protect Safari data. Cairn does not change permissions or request Full Disk Access. Export bookmarks from Safari, then choose the bookmarks HTML file instead. HTML contains no history."

    public struct Result: Sendable {
        public var bookmarks: [ImportedBookmark]
        public var skipped: SkipCounts
    }

    public static func parse(_ data: Data, isCancelled: () -> Bool = { Task.isCancelled }) throws -> Result {
        if isCancelled() { throw CancellationError() }
        guard data.count <= ImportLimits.maximumFileBytes else { throw ImportError.tooLarge("Bookmarks.plist") }
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let children = root["Children"] as? [Any] else {
            throw ImportError.malformed("Expected Safari Bookmarks.plist with a Children array.")
        }
        var parsed = ParsedBookmarks()
        var visited = 0
        func walk(_ children: [Any], path: [String], depth: Int) throws {
            guard depth <= 64 else { throw ImportError.tooLarge("Safari bookmark nesting") }
            for raw in children {
                if isCancelled() { throw CancellationError() }
                visited += 1
                guard visited <= ImportLimits.maximumBookmarks * 4 else { throw ImportError.tooLarge("Safari bookmark structure") }
                guard let node = raw as? [String: Any], let type = node["WebBookmarkType"] as? String else {
                    throw ImportError.malformed("Invalid Safari bookmark item.")
                }
                if node["ShouldOmitFromUI"] as? Bool == true {
                    parsed.skipped[.unsupportedItem, default: 0] += 1
                    continue
                }
                switch type {
                case "WebBookmarkTypeList":
                    guard let title = node["Title"] as? String,
                          node["Children"] == nil || node["Children"] is [Any] else {
                        throw ImportError.malformed("Invalid Safari bookmark folder.")
                    }
                    if title == "com.apple.ReadingList" {
                        parsed.skipped[.unsupportedItem, default: 0] += 1
                        continue
                    }
                    let name = title == "BookmarksBar" ? "Favorites" : (title == "BookmarksMenu" ? "Bookmarks Menu" : title)
                    try walk(node["Children"] as? [Any] ?? [], path: path + [name], depth: depth + 1)
                case "WebBookmarkTypeLeaf":
                    guard let address = node["URLString"] as? String,
                          node["URIDictionary"] == nil || node["URIDictionary"] is [String: Any] else {
                        throw ImportError.malformed("Invalid Safari bookmark URL or title.")
                    }
                    let details = node["URIDictionary"] as? [String: Any]
                    guard details?["title"] == nil || details?["title"] is String else {
                        throw ImportError.malformed("Invalid Safari bookmark title.")
                    }
                    parsed.add(title: details?["title"] as? String ?? "", address: address, folderPath: path)
                default:
                    parsed.skipped[.unsupportedItem, default: 0] += 1
                }
            }
        }
        try walk(children, path: [], depth: 0)
        return Result(bookmarks: parsed.bookmarks, skipped: parsed.skipped)
    }
}
