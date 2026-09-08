// Renders the Tiled logo: the app squircle in white carrying the
// menu-bar glyph (the sixths grid), bottom-left and bottom-right cells
// filled solid black, the other four greyed out.
//
// The grid keeps the status glyph's shape language: one shared outer
// frame subdivided, so only each corner cell's outer corner rounds and
// the middle-column cells stay fully square; cells are wider than tall,
// like real sixths on a display.
//
// Usage: swift scripts/make-logo.swift <output-dir>
// Writes logo-<px>.png at the standard iconset sizes.

import AppKit

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "build/logo"

// Sixths layout: 3 columns × 2 rows. Filled cells read as occupied
// tiles; the rest read as empty slots.
let filledCells: Set<[Int]> = [
    [0, 1],  // bottom left (col 0, visual bottom row)
    [2, 1],  // bottom right
]

enum IconCorner { case topLeft, topRight, bottomLeft, bottomRight }

func cellPath(
    rect: CGRect, roundedCorners: Set<IconCorner>, radius: CGFloat
) -> NSBezierPath {
    guard radius > 0, !roundedCorners.isEmpty else {
        return NSBezierPath(rect: rect)
    }
    let minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
    let path = NSBezierPath()
    if roundedCorners.contains(.topLeft) {
        path.move(to: NSPoint(x: minX + radius, y: maxY))
    } else {
        path.move(to: NSPoint(x: minX, y: maxY))
    }
    if roundedCorners.contains(.topRight) {
        path.line(to: NSPoint(x: maxX - radius, y: maxY))
        path.appendArc(
            withCenter: NSPoint(x: maxX - radius, y: maxY - radius),
            radius: radius, startAngle: 90, endAngle: 0, clockwise: true)
    } else {
        path.line(to: NSPoint(x: maxX, y: maxY))
    }
    if roundedCorners.contains(.bottomRight) {
        path.line(to: NSPoint(x: maxX, y: minY + radius))
        path.appendArc(
            withCenter: NSPoint(x: maxX - radius, y: minY + radius),
            radius: radius, startAngle: 0, endAngle: 270, clockwise: true)
    } else {
        path.line(to: NSPoint(x: maxX, y: minY))
    }
    if roundedCorners.contains(.bottomLeft) {
        path.line(to: NSPoint(x: minX + radius, y: minY))
        path.appendArc(
            withCenter: NSPoint(x: minX + radius, y: minY + radius),
            radius: radius, startAngle: 270, endAngle: 180, clockwise: true)
    } else {
        path.line(to: NSPoint(x: minX, y: minY))
    }
    if roundedCorners.contains(.topLeft) {
        path.line(to: NSPoint(x: minX, y: maxY - radius))
        path.appendArc(
            withCenter: NSPoint(x: minX + radius, y: maxY - radius),
            radius: radius, startAngle: 180, endAngle: 90, clockwise: true)
    } else {
        path.line(to: NSPoint(x: minX, y: maxY))
    }
    path.close()
    return path
}

func drawLogo(size: CGFloat) {
    // macOS icon grid: content squircle inset ~10% with ~22% corner
    // radius, per the Big Sur template proportions.
    let inset = size * 0.10
    let rect = CGRect(
        x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let squircle = NSBezierPath(
        roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.height * 0.225)

    // Background: white, with a hairline border so the squircle edge
    // survives against white chrome.
    NSColor.white.setFill()
    squircle.fill()
    NSColor(white: 0, alpha: 0.10).setStroke()
    let border = NSBezierPath(
        roundedRect: rect.insetBy(dx: size * 0.004, dy: size * 0.004),
        xRadius: rect.width * 0.22, yRadius: rect.height * 0.22)
    border.lineWidth = max(size * 0.004, 1)
    border.stroke()

    drawGrid(
    in: rect.insetBy(dx: rect.width * 0.16, dy: rect.width * 0.16))
}

func drawGrid(in grid: CGRect) {
    let gap = grid.width * 0.055
    let cellWidth = (grid.width - gap * 2) / 3
    // Square cells, like the status glyph's: the grid reads landscape
    // and unstretched, centered with breathing room above and below.
    let cellHeight = cellWidth
    let gridHeight = cellHeight * 2 + gap
    let originX = grid.minX
    let originY = grid.midY - gridHeight / 2

    let cornerRadius = cellHeight * 0.24

    for col in 0..<3 {
        for row in 0..<2 {
            // AppKit y grows upward: row 0 is the visual top.
            let x = originX + CGFloat(col) * (cellWidth + gap)
            let y = originY + CGFloat(1 - row) * (cellHeight + gap)
            let rect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
            var corners: Set<IconCorner> = []
            if col == 0, row == 0 { corners.insert(.topLeft) }
            if col == 2, row == 0 { corners.insert(.topRight) }
            if col == 0, row == 1 { corners.insert(.bottomLeft) }
            if col == 2, row == 1 { corners.insert(.bottomRight) }
            let path = cellPath(rect: rect, roundedCorners: corners, radius: cornerRadius)
            if filledCells.contains([col, row]) {
                NSColor.black.setFill()
                path.fill()
            } else {
                // Idle cells grey out, exactly like the status glyph's
                // unoccupied slots: same rect, so the grid never shifts
                // weight between states.
                NSColor.black.withAlphaComponent(0.35).setFill()
                path.fill()
            }
        }
    }
}

func render(_ px: Int) throws -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawLogo(size: CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-logo", code: 1)
    }
    return png
}

try FileManager.default.createDirectory(
    atPath: outDir, withIntermediateDirectories: true)
for px in [1024, 512, 256, 128, 64, 32] {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("logo-\(px).png")
    try render(px).write(to: url)
    print("wrote \(url.path)")
}
