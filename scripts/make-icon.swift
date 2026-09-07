// Renders the Tiled app icon into an .iconset directory: a dark squircle
// carrying a 2×2 grid of tiles with Top Left lit in accent blue — the
// product's first lesson ("press ⌥⇧U to tile top-left") as a picture.
//
// Usage: swift scripts/make-icon.swift <iconset-dir>
// Follow with: iconutil -c icns <iconset-dir> -o Resources/AppIcon.icns

import AppKit

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "build/AppIcon.iconset"

func drawIcon(size: CGFloat) {
    // macOS icon grid: content squircle inset ~10% with ~22% corner
    // radius, per the Big Sur template proportions.
    let inset = size * 0.10
    let rect = CGRect(
        x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let squircle = NSBezierPath(
        roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.height * 0.225)

    // Background: vertical dark gradient.
    let background = NSGradient(
        starting: NSColor(srgbRed: 0.20, green: 0.21, blue: 0.24, alpha: 1),
        ending: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1))
    background?.draw(in: squircle, angle: -90)

    // 2×2 tile grid. Top-left tile lit in accent blue, the rest dimmed —
    // the quarters layout, with the slot the Welcome tab teaches first.
    let pad = rect.width * 0.18
    let grid = rect.insetBy(dx: pad, dy: pad)
    let gap = grid.width * 0.08
    let cell = (grid.width - gap) / 2
    let cellRadius = cell * 0.22
    for col in 0..<2 {
        for row in 0..<2 {
            // AppKit y grows upward: row 0 is the visual top.
            let x = grid.minX + CGFloat(col) * (cell + gap)
            let y = grid.minY + CGFloat(1 - row) * (cell + gap)
            let tile = NSBezierPath(
                roundedRect: CGRect(x: x, y: y, width: cell, height: cell),
                xRadius: cellRadius, yRadius: cellRadius)
            if col == 0 && row == 0 {
                NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1).setFill()
            } else {
                NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22).setFill()
            }
            tile.fill()
        }
    }
}

// Renders one exact-pixel-size PNG; drawing straight into a bitmap rep
// avoids point/pixel scaling surprises at the small sizes.
func render(_ px: Int) throws -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    return png
}

// Full Apple iconset manifest: every size the template expects.
let entries: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

try FileManager.default.createDirectory(
    atPath: outDir, withIntermediateDirectories: true)
for entry in entries {
    let data = try render(entry.px)
    try data.write(to: URL(fileURLWithPath: "\(outDir)/\(entry.name)"))
}
print("Wrote \(entries.count) sizes to \(outDir)")
