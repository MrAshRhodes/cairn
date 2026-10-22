import Foundation

/// The visual editor's settings. Every field is optional; nil means "leave the page alone".
public struct BoostStyle: Codable, Hashable, Sendable {
    public enum FontPreset: String, Codable, CaseIterable, Sendable {
        case system, serif, mono, rounded
        public var stack: String {
            switch self {
            case .system: return "-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", sans-serif"
            case .serif: return "\"New York\", Georgia, \"Times New Roman\", serif"
            case .mono: return "ui-monospace, Menlo, Consolas, monospace"
            case .rounded: return "ui-rounded, \"SF Pro Rounded\", system-ui, sans-serif"
            }
        }
    }
    public enum TextCase: String, Codable, CaseIterable, Sendable { case uppercase, lowercase, capitalize }

    public static let adjustmentRange = 0.5...1.5
    public static let fontScaleRange = 0.9...1.5
    public static let maximumTintAmount = 0.6

    /// `#RRGGBB` overlay colour.
    public var tintHex: String?
    /// 0...0.6, strength of the tint.
    public var tintAmount: Double?
    public var invertLightness: Bool?
    /// 0.5...1.5, where 1 is unchanged.
    public var contrast: Double?
    public var brightness: Double?
    public var saturation: Double?
    public var fontPreset: FontPreset?
    /// 0.9...1.5, relative root font size.
    public var fontScale: Double?
    public var textCase: TextCase?

    public init(tintHex: String? = nil, tintAmount: Double? = nil, invertLightness: Bool? = nil, contrast: Double? = nil,
                brightness: Double? = nil, saturation: Double? = nil, fontPreset: FontPreset? = nil,
                fontScale: Double? = nil, textCase: TextCase? = nil) {
        self.tintHex = tintHex; self.tintAmount = tintAmount; self.invertLightness = invertLightness
        self.contrast = contrast; self.brightness = brightness; self.saturation = saturation
        self.fontPreset = fontPreset; self.fontScale = fontScale; self.textCase = textCase
    }

    /// True when no setting changes the page.
    public var isEmpty: Bool { self == BoostStyle() || normalized == BoostStyle() }

    /// Drops values equal to their defaults so "reset" and "unchanged" compare equal.
    public var normalized: BoostStyle {
        var copy = self
        if copy.tintHex == nil || (copy.tintAmount ?? 0.15) == 0 { copy.tintHex = nil; copy.tintAmount = nil }
        if copy.invertLightness == false { copy.invertLightness = nil }
        for key in [\BoostStyle.contrast, \.brightness, \.saturation] where copy[keyPath: key] == 1 { copy[keyPath: key] = nil }
        if copy.fontScale == 1 { copy.fontScale = nil }
        return copy
    }

    func validate() throws {
        if let tintHex, tintHex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) == nil {
            throw BoostError.invalid("The tint must be a #RRGGBB colour.")
        }
        for (name, value, range) in [("tint strength", tintAmount, 0...Self.maximumTintAmount), ("contrast", contrast, Self.adjustmentRange),
                                     ("brightness", brightness, Self.adjustmentRange), ("saturation", saturation, Self.adjustmentRange),
                                     ("text size", fontScale, Self.fontScaleRange)] {
            if let value, !(value.isFinite && range.contains(value)) {
                throw BoostError.invalid("The \(name) is out of range.")
            }
        }
    }
}
