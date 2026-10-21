import AppKit

// Original Cairn artwork: three balanced river stones against a dusk-blue tile.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let tile = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 210, yRadius: 210)
        NSGradient(starting: NSColor(srgbRed: 0.08, green: 0.22, blue: 0.28, alpha: 1),
                   ending: NSColor(srgbRed: 0.16, green: 0.40, blue: 0.43, alpha: 1))!.draw(in: tile, angle: 70)
        let stones: [(NSRect, NSColor)] = [
            (NSRect(x: 220, y: 234, width: 584, height: 166), NSColor(srgbRed: 0.69, green: 0.78, blue: 0.72, alpha: 1)),
            (NSRect(x: 288, y: 424, width: 448, height: 156), NSColor(srgbRed: 0.87, green: 0.86, blue: 0.72, alpha: 1)),
            (NSRect(x: 380, y: 602, width: 264, height: 180), NSColor(srgbRed: 0.98, green: 0.73, blue: 0.43, alpha: 1))
        ]
        for (rect, color) in stones {
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(
            to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        )
    }
}
