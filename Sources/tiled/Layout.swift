import CoreGraphics

/// Which tiling geometry a slot belongs to.
///
/// Layouts are mutually exclusive on screen: requesting a slot in a layout
/// other than the active one resets the space (evicts every tiled window)
/// and switches to the requested layout. See `TilingState.plan(window:into:)`.
enum LayoutKind: String {
    case quarters
    case sixths

    var title: String {
        switch self {
        case .quarters: "Quarters"
        case .sixths: "Sixths"
        }
    }
}

/// Atomic tiling cell: the common refinement of the quarters split (1/2)
/// and the sixths splits (1/3, 2/3). Four vertical strips x top/bottom rows.
///
/// Strips run left to right: 0 = [0, 1/3), 1 = [1/3, 1/2),
/// 2 = [1/2, 2/3), 3 = [2/3, 1].
enum TileCell: String, CaseIterable, Hashable {
    case col0Top, col1Top, col2Top, col3Top
    case col0Bottom, col1Bottom, col2Bottom, col3Bottom
}

extension TileCell {
    /// The cell at refinement strip `column` (0..<4) and row `row`
    /// (0 = top, 1 = bottom), the inverse of the case order above.
    init(column: Int, row: Int) {
        self = Self.allCases[column + 4 * row]
    }
}

/// One slot's structural geometry: the single declaration every derived
/// property reads: which layout it belongs to, and the span of refinement
/// strips (columns) and rows it covers.
///
/// The shared 4×2 refinement gives both layouts one coordinate space:
/// columns 0..<4 run left to right (quarters pair strips 0–1 and 2–3;
/// sixths use single strips, the middle pair, and the two wide spans);
/// rows 0..<2 run top to bottom. Cells, overlap, and rects all derive
/// from the span, so a slot's geometry can never disagree with its cells
/// or its rect the way parallel hand-written tables could.
struct SlotGeometry: Equatable {
    let layout: LayoutKind
    /// Refinement strips covered, left to right (0..<4).
    let columns: Range<Int>
    /// Refinement rows covered, top to bottom (0 = top, 1 = bottom).
    let rows: Range<Int>
}

/// A tile a window can occupy, defined structurally by `geometry`.
///
/// Overlap rule: two slots overlap iff their spans intersect (equivalently,
/// their cell sets intersect). The controller enforces "one window per
/// tile" via the eviction rules in `TilingState.plan(window:into:)`.
///
/// Quarters slots tile the screen as 2x2 quads plus full-column halves.
/// Sixths slots tile it as a 3x2 grid (corner/middle sixths) plus
/// full-height thirds and two-thirds.
enum Slot: String, CaseIterable {
    // Quarters
    case topLeft, topRight, bottomLeft, bottomRight
    case leftHalf, rightHalf
    // Sixths: corners, middles, thirds, two-thirds
    case sixthTopLeft, sixthTopMiddle, sixthTopRight
    case sixthBottomLeft, sixthBottomMiddle, sixthBottomRight
    case sixthLeft, sixthMiddle, sixthRight
    case sixthsLeftTwoThirds, sixthsRightTwoThirds

    /// The slot's span of the shared 4×2 refinement. One declaration per
    /// slot; every derived property below reads it.
    var geometry: SlotGeometry {
        switch self {
        case .topLeft: SlotGeometry(layout: .quarters, columns: 0..<2, rows: 0..<1)
        case .topRight: SlotGeometry(layout: .quarters, columns: 2..<4, rows: 0..<1)
        case .bottomLeft: SlotGeometry(layout: .quarters, columns: 0..<2, rows: 1..<2)
        case .bottomRight: SlotGeometry(layout: .quarters, columns: 2..<4, rows: 1..<2)
        case .leftHalf: SlotGeometry(layout: .quarters, columns: 0..<2, rows: 0..<2)
        case .rightHalf: SlotGeometry(layout: .quarters, columns: 2..<4, rows: 0..<2)
        case .sixthTopLeft: SlotGeometry(layout: .sixths, columns: 0..<1, rows: 0..<1)
        case .sixthTopMiddle: SlotGeometry(layout: .sixths, columns: 1..<3, rows: 0..<1)
        case .sixthTopRight: SlotGeometry(layout: .sixths, columns: 3..<4, rows: 0..<1)
        case .sixthBottomLeft: SlotGeometry(layout: .sixths, columns: 0..<1, rows: 1..<2)
        case .sixthBottomMiddle: SlotGeometry(layout: .sixths, columns: 1..<3, rows: 1..<2)
        case .sixthBottomRight: SlotGeometry(layout: .sixths, columns: 3..<4, rows: 1..<2)
        case .sixthLeft: SlotGeometry(layout: .sixths, columns: 0..<1, rows: 0..<2)
        case .sixthMiddle: SlotGeometry(layout: .sixths, columns: 1..<3, rows: 0..<2)
        case .sixthRight: SlotGeometry(layout: .sixths, columns: 3..<4, rows: 0..<2)
        case .sixthsLeftTwoThirds: SlotGeometry(layout: .sixths, columns: 0..<3, rows: 0..<2)
        case .sixthsRightTwoThirds: SlotGeometry(layout: .sixths, columns: 1..<4, rows: 0..<2)
        }
    }

    /// Which layout this slot belongs to.
    var layout: LayoutKind { geometry.layout }

    /// The cells this slot covers: its span of the shared refinement.
    var cells: Set<TileCell> {
        var covered: Set<TileCell> = []
        for column in geometry.columns {
            for row in geometry.rows {
                covered.insert(TileCell(column: column, row: row))
            }
        }
        return covered
    }

    func overlaps(_ other: Slot) -> Bool {
        geometry.columns.overlaps(other.geometry.columns)
            && geometry.rows.overlaps(other.geometry.rows)
    }
}

/// An edge of a window's frame.
enum TileEdge: CaseIterable {
    case left, right, top, bottom
}

/// A movable boundary in the grid. Screen edges are fixed, not boundaries.
///
/// Each case is pure data: the stored fraction it reads and writes, its
/// clamp range, and any sibling it must not cross. All splitter behavior
/// (`position`, `update`) is written once against these descriptors.
enum GridBoundary: CaseIterable {
    case columnSplit // vertical divider between left and right columns
    case leftRowSplit // horizontal divider for the left column only
    case rightRowSplit // horizontal divider for the right column only
    case sixthsLeftSplit // vertical divider between the left and middle thirds
    case sixthsRightSplit // vertical divider between the middle and right thirds
    case sixthsLeftRowSplit // horizontal divider for the left third only
    case sixthsMiddleRowSplit // horizontal divider for the middle third only
    case sixthsRightRowSplit // horizontal divider for the right third only

    /// The axis a splitter's fraction measures across.
    enum Axis { case vertical, horizontal }

    var axis: Axis {
        switch self {
        case .columnSplit, .sixthsLeftSplit, .sixthsRightSplit: .vertical
        case .leftRowSplit, .rightRowSplit, .sixthsLeftRowSplit,
            .sixthsMiddleRowSplit, .sixthsRightRowSplit: .horizontal
        }
    }

    /// The stored fraction this splitter moves.
    var fraction: WritableKeyPath<GridLayout, CGFloat> {
        switch self {
        case .columnSplit: \.columnSplit
        case .leftRowSplit: \.leftRowSplit
        case .rightRowSplit: \.rightRowSplit
        case .sixthsLeftSplit: \.sixthsLeftSplit
        case .sixthsRightSplit: \.sixthsRightSplit
        case .sixthsLeftRowSplit: \.sixthsLeftRowSplit
        case .sixthsMiddleRowSplit: \.sixthsMiddleRowSplit
        case .sixthsRightRowSplit: \.sixthsRightRowSplit
        }
    }

    /// Static fraction bounds for a wild drag.
    var clamp: ClosedRange<CGFloat> {
        switch self {
        case .columnSplit: GridLayout.columnClamp
        case .sixthsLeftSplit, .sixthsRightSplit: GridLayout.sixthsColumnClamp
        case .leftRowSplit, .rightRowSplit, .sixthsLeftRowSplit,
            .sixthsMiddleRowSplit, .sixthsRightRowSplit: GridLayout.rowClamp
        }
    }

    /// Sibling fraction this splitter must stay above (plus the minimum
    /// gap), or nil. The sixths column splitters keep each other from
    /// crossing, so a wild drag can never invert the middle third.
    var lowerSibling: WritableKeyPath<GridLayout, CGFloat>? {
        self == .sixthsRightSplit ? \.sixthsLeftSplit : nil
    }

    /// Sibling fraction this splitter must stay below (minus the minimum
    /// gap), or nil.
    var upperSibling: WritableKeyPath<GridLayout, CGFloat>? {
        self == .sixthsLeftSplit ? \.sixthsRightSplit : nil
    }
}

/// The tile grid geometry: splitter fractions over a screen's visible frame.
/// Every occupied slot's rect derives from these.
///
/// Rects, draggable edges, and splitter positions all derive from one
/// model: each layout's slots are spans of the shared 4×2 refinement
/// (see `SlotGeometry`), whose lines sit at fixed screen edges or at the
/// layout's movable splitters. Quarters route every interior vertical
/// line through the one shared `columnSplit` and give each column group
/// its own row splitter; sixths divide at 1/3 and 2/3 with one row
/// splitter per third. The layouts' splitters are independent: dragging
/// in sixths never moves quarters tiles and vice versa.
struct GridLayout: Equatable {
    /// Fraction of width where the left column ends.
    var columnSplit: CGFloat = 0.5
    /// Fraction of height where the left column's row divider sits.
    var leftRowSplit: CGFloat = 0.5
    /// Fraction of height where the right column's row divider sits.
    /// Independent from the left: dragging BL's top edge moves leftRowSplit
    /// only, so TR/BR keep their rects (and vice versa).
    var rightRowSplit: CGFloat = 0.5
    /// Fraction of width where the left sixths third ends (default 1/3).
    var sixthsLeftSplit: CGFloat = 1.0 / 3.0
    /// Fraction of width where the middle sixths third ends (default 2/3).
    var sixthsRightSplit: CGFloat = 2.0 / 3.0
    /// Fraction of height where the left third's row divider sits.
    var sixthsLeftRowSplit: CGFloat = 0.5
    /// Fraction of height where the middle third's row divider sits.
    /// Independent from the other thirds: dragging the middle column's row
    /// edge moves this only, so the left/right corners keep their rects
    /// (and symmetrically for the other columns).
    var sixthsMiddleRowSplit: CGFloat = 0.5
    /// Fraction of height where the right third's row divider sits.
    var sixthsRightRowSplit: CGFloat = 0.5

    static let columnClamp: ClosedRange<CGFloat> = 0.15...0.85
    static let rowClamp: ClosedRange<CGFloat> = 0.2...0.8
    static let sixthsColumnClamp: ClosedRange<CGFloat> = 0.1...0.9

    /// The movable splitter vertical refinement line `index` (0 = left
    /// screen edge, 4 = right) sits on in `layout`; nil for screen edges.
    /// Quarters share one column divider across all three interior lines;
    /// sixths divide at 1/3 and 2/3 (line 2 falls inside the middle
    /// third's span, which no sixths slot has an edge on, so it rides the
    /// right divider).
    static func verticalBoundary(_ index: Int, in layout: LayoutKind) -> GridBoundary? {
        switch (layout, index) {
        case (.quarters, 1...3): return .columnSplit
        case (.sixths, 1): return .sixthsLeftSplit
        case (.sixths, 2...3): return .sixthsRightSplit
        default: return nil
        }
    }

    /// The movable splitter horizontal refinement line `index` (0 = top
    /// screen edge, 1 = mid, 2 = bottom) sits on for a slot spanning
    /// `columns`; nil for screen edges. The mid line is one splitter per
    /// column group, mirroring the per-column row splits both layouts use.
    static func horizontalBoundary(
        _ index: Int, columns: Range<Int>, in layout: LayoutKind
    ) -> GridBoundary? {
        guard index == 1 else { return nil }
        switch layout {
        case .quarters:
            return columns.lowerBound == 0 ? .leftRowSplit : .rightRowSplit
        case .sixths:
            if columns.lowerBound == 0 { return .sixthsLeftRowSplit }
            if columns.upperBound == 4 { return .sixthsRightRowSplit }
            return .sixthsMiddleRowSplit
        }
    }

    /// Which grid boundary an edge of `slot` corresponds to, derived from
    /// the slot's span: left/right edges ride the vertical refinement
    /// lines at the column span's bounds, top/bottom edges the horizontal
    /// lines at the row span's bounds. nil = screen edge (fixed, cannot
    /// be dragged).
    static func boundary(edge: TileEdge, slot: Slot) -> GridBoundary? {
        let g = slot.geometry
        switch edge {
        case .left: return verticalBoundary(g.columns.lowerBound, in: g.layout)
        case .right: return verticalBoundary(g.columns.upperBound, in: g.layout)
        case .top: return horizontalBoundary(g.rows.lowerBound, columns: g.columns, in: g.layout)
        case .bottom: return horizontalBoundary(g.rows.upperBound, columns: g.columns, in: g.layout)
        }
    }

    /// The screen-space position of a boundary within `bounds` (AppKit coords).
    func position(of boundary: GridBoundary, in bounds: CGRect) -> CGFloat {
        let fraction = self[keyPath: boundary.fraction]
        switch boundary.axis {
        case .vertical: return bounds.minX + fraction * bounds.width
        case .horizontal: return bounds.minY + fraction * bounds.height
        }
    }

    /// Moves a boundary to an absolute screen-space position (clamped).
    /// Returns true if the value changed meaningfully. Refuses degenerate
    /// bounds or non-finite positions: a zero-size frame would divide by
    /// zero and poison a splitter with ±inf/NaN, corrupting every rect
    /// derived from it afterwards.
    @discardableResult
    mutating func update(
        boundary: GridBoundary, toPosition position: CGFloat, in bounds: CGRect
    ) -> Bool {
        guard bounds.width > 0, bounds.height > 0, position.isFinite else { return false }
        let origin = boundary.axis == .vertical ? bounds.minX : bounds.minY
        let span = boundary.axis == .vertical ? bounds.width : bounds.height
        let raw = (position - origin) / span
        var clamped = min(max(raw, boundary.clamp.lowerBound), boundary.clamp.upperBound)
        // Sibling ordering: a splitter can never cross the one beside it.
        if let lower = boundary.lowerSibling {
            clamped = max(clamped, self[keyPath: lower] + 0.01)
        }
        if let upper = boundary.upperSibling {
            clamped = min(clamped, self[keyPath: upper] - 0.01)
        }
        let current = self[keyPath: boundary.fraction]
        guard abs(clamped - current) > 0.001 else { return false }
        self[keyPath: boundary.fraction] = clamped
        return true
    }

    /// Screen-space x of vertical refinement line `index` within `bounds`.
    private func verticalLinePosition(_ index: Int, in layout: LayoutKind, bounds: CGRect)
        -> CGFloat
    {
        switch index {
        case 0: return bounds.minX
        case 4: return bounds.maxX
        default: return position(of: Self.verticalBoundary(index, in: layout)!, in: bounds)
        }
    }

    /// Screen-space y of horizontal refinement line `index` (0 = top,
    /// 2 = bottom) for a slot spanning `columns`.
    private func horizontalLinePosition(
        _ index: Int, columns: Range<Int>, in layout: LayoutKind, bounds: CGRect
    ) -> CGFloat {
        switch index {
        case 0: return bounds.maxY
        case 2: return bounds.minY
        default:
            return position(
                of: Self.horizontalBoundary(index, columns: columns, in: layout)!, in: bounds)
        }
    }

    /// Rect for `slot` within `bounds` (AppKit coordinates, y grows upward):
    /// the product of the slot's column and row span boundary lines.
    func rect(for slot: Slot, in bounds: CGRect) -> CGRect {
        let g = slot.geometry
        let x0 = verticalLinePosition(g.columns.lowerBound, in: g.layout, bounds: bounds)
        let x1 = verticalLinePosition(g.columns.upperBound, in: g.layout, bounds: bounds)
        let yTop = horizontalLinePosition(
            g.rows.lowerBound, columns: g.columns, in: g.layout, bounds: bounds)
        let yBottom = horizontalLinePosition(
            g.rows.upperBound, columns: g.columns, in: g.layout, bounds: bounds)
        return CGRect(x: x0, y: yBottom, width: x1 - x0, height: yTop - yBottom)
    }
}

/// Opaque window handle used by the pure layout state.
/// The controller maps these to live AXUIElements.
typealias WindowID = Int

/// What the controller should do for a tiling request.
enum TilePlan: Equatable {
    /// Place the window; the listed windows must be untiled (restored) first.
    case tile(evicting: [WindowID])
    /// The request targets a different layout than the active one: every
    /// tiled window is untiled (restored), the layout switches, and the
    /// requesting window is placed into the target slot.
    case switchLayout(evicting: [WindowID])
    /// The window already occupies the slot; nothing happens.
    case noop
}

extension TilePlan {
    /// Windows the controller must restore (untile) before committing this
    /// plan for `requester`.
    ///
    /// `.switchLayout`'s eviction set names every tiled window, including
    /// the requester itself when it is already tiled, but the requester
    /// is moving, not being evicted: its old tile is vacated by the
    /// subsequent commit, and its record (and pre-tile frame) must survive
    /// until `place` runs. Restoring it first would delete its record, so
    /// `place` would bail and the window would merely untile instead of
    /// landing in its new tile. `.tile` never names the requester
    /// (blockers exclude it by construction), so the filter is a no-op
    /// there; `.noop` restores nothing.
    func windowsToRestore(requester: WindowID) -> [WindowID] {
        switch self {
        case .tile(let evicting), .switchLayout(let evicting):
            return evicting.filter { $0 != requester }
        case .noop:
            return []
        }
    }
}

/// Pure tiling state: which window occupies which slot.
/// No AppKit, no AX; fully unit-testable.
struct TilingState: Equatable {
    private(set) var occupantBySlot: [Slot: WindowID] = [:]

    init() {}

    func occupant(of slot: Slot) -> WindowID? { occupantBySlot[slot] }

    func slot(of window: WindowID) -> Slot? {
        occupantBySlot.first(where: { $0.value == window })?.key
    }

    var occupants: [Slot: WindowID] { occupantBySlot }

    var tiledWindows: [WindowID] { Array(Set(occupantBySlot.values)) }

    /// The layout currently on screen: the layout of any tiled window, or
    /// quarters when the space is empty (quarters hotkeys tile without a
    /// reset on first use).
    var activeLayout: LayoutKind {
        occupantBySlot.keys.first.map(\.layout) ?? .quarters
    }

    /// Decides what happens when `window` requests `slot`: the requester
    /// owns `slot` after the move, and any window overlapping the target
    /// is evicted (restored to its pre-tile frame).
    func plan(window: WindowID, into slot: Slot) -> TilePlan {
        if occupantBySlot[slot] == window { return .noop }
        if !occupantBySlot.isEmpty, slot.layout != activeLayout {
            return .switchLayout(evicting: tiledWindows.sorted())
        }
        let blockers = occupantBySlot
            .filter { $0.value != window && $0.key.overlaps(slot) }
            .map(\.value)
            .sorted()
        return .tile(evicting: blockers)
    }

    /// Commit a planned placement. Evicted windows must already be removed
    /// via `remove(window:)`. Claiming an occupied slot evicts its
    /// occupant from state (the gateway write decides the truth on
    /// screen; callers roll back on refusal, as `place` does).
    mutating func commit(window: WindowID, into slot: Slot) {
        for s in Slot.allCases where occupantBySlot[s] == window {
            occupantBySlot[s] = nil
        }
        occupantBySlot[slot] = window
    }

    mutating func remove(window: WindowID) {
        for s in Slot.allCases where occupantBySlot[s] == window {
            occupantBySlot[s] = nil
        }
    }
}
