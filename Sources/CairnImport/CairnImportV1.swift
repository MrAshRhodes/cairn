import Foundation

/// `cairn-import-v1`: Cairn's own, documented interchange format (see docs/IMPORT_SCHEMA.md).
public enum CairnImportV1 {
    public static let formatName = "cairn-import-v1"

    public struct SpaceData: Sendable {
        public var name: String
        public var icon: String?
        public var colorHex: String?
        public var bookmarks: [ImportedBookmark]
    }

    public struct Result: Sendable {
        public var spaces: [SpaceData]
        public var history: [ImportedHistoryEntry]
        public var skipped: SkipCounts
    }

    public static func parse(_ data: Data) throws -> Result {
        guard data.count <= ImportLimits.maximumFileBytes else { throw ImportError.tooLarge("Import file") }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.malformed("Expected a JSON object.")
        }
        if let format = root["format"] as? String, format != formatName {
            throw ImportError.malformed("Unsupported format \"\(format)\"; expected \(formatName).")
        }
        guard root["spaces"] is [Any] || root["history"] is [Any] else {
            throw ImportError.malformed("Expected a \"spaces\" or \"history\" array.")
        }
        var skipped = SkipCounts()
        var total = 0
        var spaces: [SpaceData] = []
        for raw in root["spaces"] as? [[String: Any]] ?? [] {
            guard let name = (raw["name"] as? String).map(Sanitizer.title), !name.isEmpty else {
                throw ImportError.malformed("Every space needs a name.")
            }
            var parsed = ParsedBookmarks()
            for item in raw["pinned"] as? [[String: Any]] ?? [] {
                total += 1
                guard total <= ImportLimits.maximumBookmarks else { skipped[.overLimit, default: 0] += 1; continue }
                parsed.add(title: item["title"] as? String ?? "", address: item["url"] as? String ?? "",
                           folderPath: (item["folder"] as? [Any] ?? []).compactMap { $0 as? String })
            }
            skipped.merge(parsed.skipped, uniquingKeysWith: +)
            let color = (raw["colorHex"] as? String).flatMap {
                $0.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil ? $0 : nil
            }
            spaces.append(SpaceData(name: String(name.prefix(256)), icon: (raw["icon"] as? String).map { String($0.prefix(64)) },
                                    colorHex: color, bookmarks: parsed.bookmarks))
        }
        var history: [ImportedHistoryEntry] = []
        for item in root["history"] as? [[String: Any]] ?? [] {
            guard history.count < ImportLimits.maximumHistoryRows else { skipped[.overLimit, default: 0] += 1; continue }
            switch Sanitizer.webURL(item["url"] as? String ?? "") {
            case .success(let url):
                guard let date = date(from: item["lastVisit"]) else { skipped[.invalidURL, default: 0] += 1; continue }
                history.append(ImportedHistoryEntry(url: url, title: Sanitizer.title(item["title"] as? String ?? ""), lastVisit: date))
            case .failure(let reason):
                skipped[reason, default: 0] += 1
            }
        }
        return Result(spaces: spaces, history: history, skipped: skipped)
    }

    private static func date(from value: Any?) -> Date? {
        if let seconds = value as? Double, seconds.isFinite, seconds > 0 { return Date(timeIntervalSince1970: seconds) }
        if let text = value as? String { return ISO8601DateFormatter().date(from: text) }
        return nil
    }
}
