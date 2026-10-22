import Foundation

struct ParsedBookmarks: Sendable {
    var bookmarks: [ImportedBookmark] = []
    var skipped: SkipCounts = [:]
    var truncated = false

    mutating func add(title: String, address: String, folderPath: [String]) {
        guard bookmarks.count < ImportLimits.maximumBookmarks else {
            skipped[.overLimit, default: 0] += 1
            return
        }
        switch Sanitizer.webURL(address) {
        case .success(let url):
            let name = Sanitizer.title(title)
            bookmarks.append(ImportedBookmark(title: name.isEmpty ? (url.host ?? url.absoluteString) : name, url: url,
                                              folderPath: folderPath.map(Sanitizer.folder).filter { !$0.isEmpty }))
        case .failure(let reason):
            skipped[reason, default: 0] += 1
        }
    }
}
