import AppKit

/// Miniature spatial preview of one or more slots: a rounded-rect grid
/// with the slot's `TileCell`s filled in the accent color and the rest a
/// subtle track. Draws from the same cell sets as the layout engine, so
/// the picture cannot disagree with the geometry.
///
/// The 4-column × 2-row cell grid is the common refinement both layouts
/// share: quarters quads are 2×1 cell blocks, sixths corners/middles are
/// 1- or 2-cell blocks, halves/thirds span full rows.
final class SlotPreviewView: NSView {
    private let highlighted: Set<Slot>
    private let trackColor: NSColor
    private let displayColumns: Int

    /// - Parameter highlighted: slots to fill. Multiple slots union.
    /// - Parameter trackColor: fill for uncovered cells. Defaults to the
    ///   system quaternary label color; pass `.tertiaryLabelColor` for
    ///   small sizes in Dark Mode, where quaternary can render
    ///   near-invisible against the window background.
    /// - Parameter displayColumns: 4 (the shared refinement) or 3 for a
    ///   sixths-shaped preview; refinement cols 0..3 fold onto display
    ///   cols 0..2 (1+2 merge into the middle third), so sixths geometry
    ///   reads as three columns instead of an uneven quarter grid.
    init(
        highlighted: Set<Slot>, trackColor: NSColor = .quaternaryLabelColor,
        displayColumns: Int = 4
    ) {
        self.highlighted = highlighted
        self.trackColor = trackColor
        self.displayColumns = displayColumns
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Cells covered by any highlighted slot, as (column, row): col
    /// 0..displayColumns-1 left to right, row 0 = top. The 4-col refinement
    /// maps straight through; the 3-col sixths display folds cols 1+2 into
    /// the middle column so thirds read as thirds.
    private var filledCells: Set<String> {
        var out = Set<String>()
        for slot in highlighted {
            for cell in slot.cells {
                let (col, row): (Int, Int)
                switch cell {
                case .col0Top: (col, row) = (0, 0)
                case .col1Top: (col, row) = (1, 0)
                case .col2Top: (col, row) = (2, 0)
                case .col3Top: (col, row) = (3, 0)
                case .col0Bottom: (col, row) = (0, 1)
                case .col1Bottom: (col, row) = (1, 1)
                case .col2Bottom: (col, row) = (2, 1)
                case .col3Bottom: (col, row) = (3, 1)
                }
                out.insert("\(displayColumns == 3 ? (col >= 3 ? 2 : min(col, 1)) : col),\(row)")
            }
        }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let filled = filledCells
        // displayColumns (4 refinement or 3 sixths) × 2 rows. Gap and
        // corner radius scale with size so the miniature stays legible at
        // the 160×100 Welcome size.
        let gap = max(1, min(bounds.width, bounds.height) / 50)
        let radius = max(2, min(bounds.width, bounds.height) / 25)
        let cellW = bounds.width / CGFloat(displayColumns)
        let cellH = bounds.height / 2
        for col in 0..<displayColumns {
            for row in 0..<2 {
                let rect = NSRect(
                    x: CGFloat(col) * cellW + gap, y: CGFloat(row) * cellH + gap,
                    width: cellW - gap * 2, height: cellH - gap * 2)
                let path = CGPath(
                    roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                    transform: nil)
                ctx.addPath(path)
                if filled.contains("\(col),\(1 - row)") {
                    // Note: AppKit y grows upward; row 0 is the visual top.
                    NSColor.controlAccentColor.setFill()
                } else {
                    trackColor.setFill()
                }
                ctx.fillPath()
            }
        }
    }
}


