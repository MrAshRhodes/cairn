import AppKit
import SwiftUI
import CairnCore

extension Color {
    /// `#RRGGBB` in sRGB, for storing a picked colour.
    var cairnHexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}

extension SpaceTheme {
    func gradient(opacityScale: Double = 1) -> LinearGradient {
        let radians = angle * .pi / 180
        let dx = cos(radians) / 2, dy = sin(radians) / 2
        let alpha = intensity * 0.5 * opacityScale
        return LinearGradient(colors: [Color(cairnHex: primaryHex).opacity(alpha), Color(cairnHex: secondaryHex).opacity(alpha)],
                              startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy), endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
    }
}

/// Editor for a Space's optional two-colour theme.
struct SpaceThemeView: View {
    @Binding var theme: SpaceTheme?
    let fallbackHex: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Gradient theme", isOn: Binding(
                get: { theme != nil },
                set: { theme = $0 ? SpaceTheme(primaryHex: fallbackHex, secondaryHex: "#687FA0") : nil }))
            if let current = theme {
                HStack(spacing: 14) {
                    ColorPicker("Start", selection: colorBinding(\.primaryHex, current))
                    ColorPicker("End", selection: colorBinding(\.secondaryHex, current))
                }
                HStack {
                    Text("Angle").font(.caption)
                    Slider(value: Binding(get: { theme?.angle ?? 0 }, set: { theme?.angle = $0 }), in: 0...360)
                        .accessibilityLabel("Theme angle")
                }
                HStack {
                    Text("Intensity").font(.caption)
                    Slider(value: Binding(get: { theme?.intensity ?? 0 }, set: { theme?.intensity = $0 }), in: 0...1)
                        .accessibilityLabel("Theme intensity")
                }
                RoundedRectangle(cornerRadius: 8).fill(current.gradient(opacityScale: 2)).frame(height: 24)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary)).accessibilityHidden(true)
            }
        }
    }

    private func colorBinding(_ key: WritableKeyPath<SpaceTheme, String>, _ current: SpaceTheme) -> Binding<Color> {
        Binding(get: { Color(cairnHex: theme?[keyPath: key] ?? current[keyPath: key]) },
                set: { theme?[keyPath: key] = $0.cairnHexString })
    }
}
