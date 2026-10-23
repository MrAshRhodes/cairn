import SwiftUI
import CairnBoosts

/// Visual controls for a Boost: tint, lightness, contrast, fonts, and zapped elements. Edits the draft in place;
/// the host view saves it with the rest of the Boost.
@MainActor
struct BoostStyleEditor: View {
    @Binding var boost: Boost
    let onZap: () -> Void
    let zapping: Bool

    private var style: Binding<BoostStyle> {
        Binding(get: { boost.style ?? BoostStyle() }, set: { boost.style = $0.normalized.isEmpty ? nil : $0 })
    }
    private var tint: Binding<Color> {
        Binding(get: { Color(hex: style.wrappedValue.tintHex ?? "#007AFF") },
                set: { value in
                    var copy = style.wrappedValue
                    copy.tintHex = value.hexString
                    copy.tintAmount = copy.tintAmount ?? 0.15
                    style.wrappedValue = copy
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ColorPicker("Tint", selection: tint, supportsOpacity: false)
                Slider(value: Binding(get: { style.wrappedValue.tintAmount ?? 0 },
                                      set: { style.wrappedValue.tintAmount = $0; if style.wrappedValue.tintHex == nil { style.wrappedValue.tintHex = "#007AFF" } }),
                       in: 0...BoostStyle.maximumTintAmount).accessibilityLabel("Tint strength")
                Toggle("Invert lightness", isOn: Binding(get: { style.wrappedValue.invertLightness ?? false },
                                                         set: { style.wrappedValue.invertLightness = $0 }))
            }
            slider("Contrast", \.contrast)
            slider("Brightness", \.brightness)
            slider("Saturation", \.saturation)
            HStack {
                Picker("Font", selection: Binding(get: { style.wrappedValue.fontPreset }, set: { style.wrappedValue.fontPreset = $0 })) {
                    Text("Page default").tag(BoostStyle.FontPreset?.none)
                    ForEach(BoostStyle.FontPreset.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                }
                Picker("Case", selection: Binding(get: { style.wrappedValue.textCase }, set: { style.wrappedValue.textCase = $0 })) {
                    Text("Unchanged").tag(BoostStyle.TextCase?.none)
                    ForEach(BoostStyle.TextCase.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                }
            }
            HStack {
                Text("Text size").frame(width: 80, alignment: .leading)
                Slider(value: Binding(get: { style.wrappedValue.fontScale ?? 1 }, set: { style.wrappedValue.fontScale = $0 }),
                       in: BoostStyle.fontScaleRange).accessibilityLabel("Text size")
                Text("\(Int(((style.wrappedValue.fontScale ?? 1) * 100).rounded()))%").monospacedDigit().frame(width: 44)
            }
            HStack {
                Button("Reset Look") { boost.style = nil }.disabled(boost.style == nil)
                Spacer()
                Button(zapping ? "Click an element on the page…" : "Zap Element", action: onZap).disabled(zapping)
                    .help("Hide an element on the current page. Press Esc to cancel.")
            }
            if let zapped = boost.zapped, !zapped.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(zapped.enumerated()), id: \.offset) { index, selector in
                        HStack {
                            Text(selector).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Restore") {
                                boost.zapped?.remove(at: index)
                                if boost.zapped?.isEmpty == true { boost.zapped = nil }
                            }.buttonStyle(.link)
                        }
                    }
                }
            }
        }
    }

    private func slider(_ title: String, _ key: WritableKeyPath<BoostStyle, Double?>) -> some View {
        HStack {
            Text(title).frame(width: 80, alignment: .leading)
            Slider(value: Binding(get: { style.wrappedValue[keyPath: key] ?? 1 }, set: { style.wrappedValue[keyPath: key] = $0 }),
                   in: BoostStyle.adjustmentRange).accessibilityLabel(title)
        }
    }
}

private extension Color {
    init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0x007AFF
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
    var hexString: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .systemBlue
        return String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()),
                      Int((color.blueComponent * 255).rounded()))
    }
}
