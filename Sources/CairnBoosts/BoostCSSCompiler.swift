import Foundation

/// Turns visual-editor settings and zapped elements into CSS. Pure and deterministic: the same input always yields
/// byte-identical output, so results can be golden-tested and diffed.
public enum BoostCSSCompiler {
    public static func compile(style: BoostStyle?, zapped: [String]?) -> String {
        var blocks: [String] = []
        if let style = style?.normalized {
            blocks += compile(style)
        }
        let selectors = (zapped ?? []).filter(ZapSelector.isSafe)
        if !selectors.isEmpty {
            blocks.append(selectors.joined(separator: ",\n") + " { display: none !important; }")
        }
        return blocks.isEmpty ? "" : "/* cairn visual edits */\n" + blocks.joined(separator: "\n")
    }

    private static let textTags = "p, li, a, span, div, h1, h2, h3, h4, h5, h6, td, th, label, button, input, textarea, select, blockquote, dd, dt"

    private static func compile(_ style: BoostStyle) -> [String] {
        var blocks: [String] = []
        var filters: [String] = []
        if style.invertLightness == true { filters.append("invert(1) hue-rotate(180deg)") }
        if let value = style.contrast { filters.append("contrast(\(number(value)))") }
        if let value = style.brightness { filters.append("brightness(\(number(value)))") }
        if let value = style.saturation { filters.append("saturate(\(number(value)))") }
        if !filters.isEmpty { blocks.append("html { filter: \(filters.joined(separator: " ")) !important; }") }
        if style.invertLightness == true {
            // Media is flipped back so photos and video keep their real colours.
            blocks.append("img, picture, video, canvas, iframe { filter: invert(1) hue-rotate(180deg) !important; }")
        }
        if let tint = style.tintHex {
            let amount = style.tintAmount ?? 0.15
            blocks.append("html::after { content: \"\"; position: fixed; inset: 0; z-index: 2147483647; pointer-events: none; "
                + "background: \(tint.lowercased()); opacity: \(number(amount)); mix-blend-mode: color; }")
        }
        if let scale = style.fontScale { blocks.append("html { font-size: \(number(scale * 100))% !important; }") }
        if let preset = style.fontPreset {
            blocks.append("body :where(\(textTags)) { font-family: \(preset.stack) !important; }")
        }
        if let textCase = style.textCase {
            blocks.append("body :where(\(textTags)) { text-transform: \(textCase.rawValue) !important; }")
        }
        return blocks
    }

    /// Fixed-precision, locale-independent number formatting (2 decimals, trailing zeros removed).
    static func number(_ value: Double) -> String {
        var text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.contains("."), text.hasSuffix("0") || text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// Selectors recorded by Zap are validated against a tiny grammar before they reach CSS, because they come from a page.
public enum ZapSelector {
    public static let maximumLength = 512
    public static let maximumPerBoost = 200

    private static let compound = #"(?:[a-zA-Z][a-zA-Z0-9-]*)?(?:\[id="[A-Za-z0-9_:.\-]{1,100}"\]|\.[A-Za-z_][A-Za-z0-9_-]{0,100}|:nth-of-type\([1-9][0-9]{0,3}\))*"#
    private static let grammar = try! NSRegularExpression(pattern: "^(?:\(compound))(?: > (?:\(compound)))*$")

    public static func isSafe(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.utf8.count <= maximumLength, selector.utf8.allSatisfy({ $0 > 31 && $0 < 127 }) else { return false }
        let range = NSRange(selector.startIndex..., in: selector)
        guard grammar.firstMatch(in: selector, range: range) != nil else { return false }
        // Each compound must select something: reject pieces that are empty.
        return selector.components(separatedBy: " > ").allSatisfy { !$0.isEmpty }
    }
}
