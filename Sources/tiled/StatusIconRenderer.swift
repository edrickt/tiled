import AppKit

/// Draws one `StatusIcon.Snapshot` as the menu bar's template glyph.
/// The snapshot is the only input and the image the only output: no
/// controller, gateway, or store reads, so the presenter's refresh pass
/// stays one value in, one image out.
enum StatusIconRenderer {
    /// The menu-bar glyph states the product's core idea twice over: the
    /// current layout's geometry, and which of its slots are occupied. The
    /// stock square.grid.2x2 symbol can't express the quarters/sixths
    /// duality and goes stale on a layout switch, so draw a small template
    /// grid (2×2 for quarters, 3×2 for sixths) with each cell solid only
    /// while a tiled window actually covers that spot, dimmed solid otherwise.
    /// An empty space reads as an empty frame; a full one reads solid.
    static func image(for snapshot: StatusIcon.Snapshot) -> NSImage {
        let cells = StatusIcon.cells(for: snapshot.layout)
        let columns = snapshot.layout == .quarters ? 2 : 3
        // One shared canvas for both layouts: with a variable-length
        // status item, per-layout widths would shove neighboring icons
        // sideways on every layout switch.
        let size = NSSize(width: 22, height: 16)
        let filled = Set(snapshot.filled)
        let image = NSImage(size: size, flipped: false) { _ in
            let margin: CGFloat = 1.5
            let gap: CGFloat = 1
            let rowCount = 2
            let cellW = (size.width - margin * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let cellH = (size.height - margin * 2 - gap) / CGFloat(rowCount)
            NSColor.black.setFill()
            // One rounded frame subdivided: only each corner cell's outer
            // corner rounds (the top-left cell's top-left corner, and so
            // on); every inner edge stays square. Middle-column cells in
            // sixths touch no outer corner and stay fully square.
            let cornerRadius: CGFloat = 2.5
            for (index, cell) in cells.enumerated() {
                let col = index % columns
                let row = index / columns
                let x = margin + CGFloat(col) * (cellW + gap)
                let y = margin + CGFloat(1 - row) * (cellH + gap)
                let rect = NSRect(x: x, y: y, width: cellW, height: cellH)
                var corners: Set<IconCorner> = []
                if col == 0, row == 0 { corners.insert(.topLeft) }
                if col == columns - 1, row == 0 { corners.insert(.topRight) }
                if col == 0, row == rowCount - 1 { corners.insert(.bottomLeft) }
                if col == columns - 1, row == rowCount - 1 { corners.insert(.bottomRight) }
                if filled.contains(cell) {
                    NSColor.black.setFill()
                    cellPath(
                        rect: rect, roundedCorners: corners, radius: cornerRadius
                    ).fill()
                } else {
                    // Idle cells render as dimmed solids, not hollow
                    // outlines: a template image carries alpha only, so
                    // reduced-opacity black composites as grey against the
                    // menu bar. Same rect as an occupied cell, so the grid
                    // never shifts weight between states.
                    NSColor.black.withAlphaComponent(0.35).setFill()
                    cellPath(
                        rect: rect, roundedCorners: corners, radius: cornerRadius
                    ).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = StatusIcon.accessibilityDescription(snapshot)
        return image
    }

    /// Which outer corner(s) of a status-icon cell round. Inner edges
    /// always stay square so the grid reads as one subdivided frame.
    enum IconCorner: Hashable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// Cell outline with only the given outer corners rounded. A zero
    /// radius (or no corners) is a plain rect.
    ///
    /// The arcs sweep clockwise (the path walks clockwise): the two-arg
    /// `appendArc` overload defaults to the counter-clockwise sweep, which
    /// balloons into the cell and punches a circular bite out of every
    /// rounded corner.
    static func cellPath(
        rect: NSRect, roundedCorners: Set<IconCorner>, radius: CGFloat
    ) -> NSBezierPath {
        guard radius > 0, !roundedCorners.isEmpty else {
            return NSBezierPath(rect: rect)
        }
        let minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        let path = NSBezierPath()
        // Start just past the top-left corner and walk clockwise.
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
}
