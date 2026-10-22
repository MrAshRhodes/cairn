import Foundation

/// A tolerant scanner for the Netscape bookmark file format every browser can export.
/// The HTML is only scanned for tags; it is never rendered or evaluated.
public enum NetscapeHTML {
    public struct Result: Sendable {
        public var bookmarks: [ImportedBookmark]
        public var skipped: SkipCounts
    }

    public static func parse(_ data: Data) throws -> Result {
        guard data.count <= ImportLimits.maximumFileBytes else { throw ImportError.tooLarge("Bookmarks file") }
        let text = String(decoding: data, as: UTF8.self)
        guard text.range(of: "<a ", options: .caseInsensitive) != nil || text.range(of: "<dl", options: .caseInsensitive) != nil else {
            throw ImportError.malformed("No bookmarks were found in this HTML file.")
        }
        var parsed = ParsedBookmarks()
        var stack: [String?] = []
        var pendingFolder: String?
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "<") {
            guard let close = text[open...].firstIndex(of: ">") else { break }
            let tag = String(text[text.index(after: open)..<close])
            index = text.index(after: close)
            let name = tag.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()
            let isClosing = tag.hasPrefix("/")
            if isClosing {
                if tag.dropFirst().lowercased() == "dl", !stack.isEmpty { stack.removeLast() }
                continue
            }
            switch name {
            case "dl":
                stack.append(pendingFolder)
                pendingFolder = nil
            case "h3":
                pendingFolder = innerText(in: text, from: index, closing: "</h3>").map { Entities.decode($0) }
            case "a":
                let address = attribute("href", in: tag).map(Entities.decode) ?? ""
                let title = innerText(in: text, from: index, closing: "</a>").map { Entities.decode($0) } ?? ""
                parsed.add(title: title, address: address, folderPath: stack.compactMap { $0 })
            default:
                break
            }
        }
        return Result(bookmarks: parsed.bookmarks, skipped: parsed.skipped)
    }

    private static func innerText(in text: String, from start: String.Index, closing: String) -> String? {
        guard let end = text.range(of: closing, options: .caseInsensitive, range: start..<text.endIndex) else { return nil }
        let inner = text[start..<end.lowerBound]
        // Strip nested tags such as <b>.
        var plain = ""
        var inTag = false
        for character in inner {
            if character == "<" { inTag = true } else if character == ">" { inTag = false } else if !inTag { plain.append(character) }
        }
        return plain
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: name + "=", options: .caseInsensitive) else { return nil }
        let rest = tag[range.upperBound...]
        guard let quote = rest.first else { return nil }
        if quote == "\"" || quote == "'" {
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: quote) else { return nil }
            return String(body[..<end])
        }
        return String(rest.prefix { !$0.isWhitespace })
    }
}

enum Entities {
    private static let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") {
                let body = String(text[text.index(after: index)..<semicolon])
                if let replacement = replacement(for: body) {
                    result += replacement
                    index = text.index(after: semicolon)
                    continue
                }
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    private static func replacement(for body: String) -> String? {
        if let value = named[body.lowercased()] { return value }
        guard body.hasPrefix("#") else { return nil }
        let digits = body.dropFirst()
        let code = digits.lowercased().hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
        return code.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }
}
