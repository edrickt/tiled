import CoreGraphics

/// Which tiling geometry a slot belongs to.
///
/// Layouts are mutually exclusive on a canvas. A canvas stores its choice
/// (`TilingState.layout`), and `⌥⇧\` switches it explicitly: every tiled
/// window is restored to its pre-tile frame and the canvas adopts the other
/// layout. A slot request never switches; a key with no slot in the active
/// layout is inert.
enum LayoutKind: String {
    case quarters
    case sixths

    var title: String {
        switch self {
        case .quarters: "Quarters"
        case .sixths: "Sixths"
        }
    }

    /// The layout an explicit switch targets.
    var other: LayoutKind {
        switch self {
        case .quarters: .sixths
        case .sixths: .quarters
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
    /// The physical key that selects this slot in `layout`. Declared on the
    /// same row as the span so the key mapping and the geometry can never
    /// drift apart.
    let key: SlotKey
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
        case .topLeft:
            SlotGeometry(layout: .quarters, key: .topLeft, columns: 0..<2, rows: 0..<1)
        case .topRight:
            SlotGeometry(layout: .quarters, key: .topRight, columns: 2..<4, rows: 0..<1)
        case .bottomLeft:
            SlotGeometry(layout: .quarters, key: .bottomLeft, columns: 0..<2, rows: 1..<2)
        case .bottomRight:
            SlotGeometry(layout: .quarters, key: .bottomRight, columns: 2..<4, rows: 1..<2)
        case .leftHalf:
            SlotGeometry(layout: .quarters, key: .leftColumn, columns: 0..<2, rows: 0..<2)
        case .rightHalf:
            SlotGeometry(layout: .quarters, key: .rightColumn, columns: 2..<4, rows: 0..<2)
        case .sixthTopLeft:
            SlotGeometry(layout: .sixths, key: .topLeft, columns: 0..<1, rows: 0..<1)
        case .sixthTopMiddle:
            SlotGeometry(layout: .sixths, key: .topMiddle, columns: 1..<3, rows: 0..<1)
        case .sixthTopRight:
            SlotGeometry(layout: .sixths, key: .topRight, columns: 3..<4, rows: 0..<1)
        case .sixthBottomLeft:
            SlotGeometry(layout: .sixths, key: .bottomLeft, columns: 0..<1, rows: 1..<2)
        case .sixthBottomMiddle:
            SlotGeometry(layout: .sixths, key: .bottomMiddle, columns: 1..<3, rows: 1..<2)
        case .sixthBottomRight:
            SlotGeometry(layout: .sixths, key: .bottomRight, columns: 3..<4, rows: 1..<2)
        case .sixthLeft:
            SlotGeometry(layout: .sixths, key: .leftColumn, columns: 0..<1, rows: 0..<2)
        case .sixthMiddle:
            SlotGeometry(layout: .sixths, key: .middleColumn, columns: 1..<3, rows: 0..<2)
        case .sixthRight:
            SlotGeometry(layout: .sixths, key: .rightColumn, columns: 3..<4, rows: 0..<2)
        case .sixthsLeftTwoThirds:
            SlotGeometry(layout: .sixths, key: .leftTwoThirds, columns: 0..<3, rows: 0..<2)
        case .sixthsRightTwoThirds:
            SlotGeometry(layout: .sixths, key: .rightTwoThirds, columns: 1..<4, rows: 0..<2)
        }
    }

    /// Which layout this slot belongs to.
    var layout: LayoutKind { geometry.layout }

    /// The physical key that selects this slot in its layout.
    var key: SlotKey { geometry.key }

    /// True for the sixths slots that span two thirds of the screen.
    /// Their span hides a one-thirds divider, which is kept centered
    /// when the slot's movable outer edge is resized.
    var isTwoThirds: Bool {
        switch self {
        case .sixthsLeftTwoThirds, .sixthsRightTwoThirds: true
        default: false
        }
    }

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

/// An edge of a window's frame. AppKit coordinates, y grows upward:
/// `.top` is the maxY side — the line where the slot's row span begins
/// (`rows.lowerBound`, the side row 0 is on) — and `.bottom` is the minY
/// side (`rows.upperBound`).
enum TileEdge: CaseIterable {
    case left, right, top, bottom

    /// Where this edge sits in `frame` (AppKit coords). One mapping, shared
    /// by the live drag loop and the reassert's reconcile.
    func position(in frame: CGRect) -> CGFloat {
        switch self {
        case .left: frame.minX
        case .right: frame.maxX
        case .top: frame.maxY
        case .bottom: frame.minY
        }
    }
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
    ///
    /// `centeringTwoThirds` names the occupied two-thirds window a drag
    /// is resizing, when there is one. Its movable outer edge and the
    /// hidden one-thirds divider inside it move together to the divider's
    /// midpoint, so a resized two-thirds window still reads as two equal
    /// one-thirds. The pair is updated atomically: the usual sibling
    /// minimum exists to keep independent splitters from crossing, but a
    /// two-thirds window's own outer edge and the divider that defines
    /// its equal halves must both move or neither can.
    @discardableResult
    mutating func update(
        boundary: GridBoundary, toPosition position: CGFloat, in bounds: CGRect,
        centeringTwoThirds slot: Slot? = nil
    ) -> Bool {
        guard bounds.width > 0, bounds.height > 0, position.isFinite else { return false }
        let origin = boundary.axis == .vertical ? bounds.minX : bounds.minY
        let span = boundary.axis == .vertical ? bounds.width : bounds.height
        let raw = (position - origin) / span
        if let slot, let symmetry = Self.twoThirdsSymmetry(
            for: slot, moving: boundary, to: raw)
        {
            var changed = write(boundary, to: symmetry.dragged)
            if write(symmetry.companion, to: symmetry.companionFraction) {
                changed = true
            }
            return changed
        }
        return updateIndependently(boundary, to: raw)
    }

    /// The occupied two-thirds window whose hidden one-thirds divider
    /// must follow `boundary`, if any. Dragging the two-thirds window's
    /// own outer edge counts directly; so does dragging the adjacent
    /// third's facing edge, since that is the same splitter resizing both
    /// windows. Any other boundary leaves the two-thirds divider alone.
    /// One declaration, shared by the live drag loop and the reassert's
    /// reconcile, so the two paths can never disagree about which hidden
    /// divider follows an edge.
    static func centeringTwoThirds(
        on boundary: GridBoundary, draggedSlot: Slot, occupants: Set<Slot>
    ) -> Slot? {
        if draggedSlot == .sixthsLeftTwoThirds, boundary == .sixthsRightSplit {
            return draggedSlot
        }
        if draggedSlot == .sixthsRightTwoThirds, boundary == .sixthsLeftSplit {
            return draggedSlot
        }
        switch boundary {
        case .sixthsRightSplit:
            return occupants.contains(.sixthsLeftTwoThirds) ? .sixthsLeftTwoThirds : nil
        case .sixthsLeftSplit:
            return occupants.contains(.sixthsRightTwoThirds) ? .sixthsRightTwoThirds : nil
        default:
            return nil
        }
    }

    /// The ordinary independent-splitter update: clamp the dragged
    /// fraction to its own range, then keep it from crossing its sibling.
    private mutating func updateIndependently(_ boundary: GridBoundary, to raw: CGFloat) -> Bool {
        var clamped = min(max(raw, boundary.clamp.lowerBound), boundary.clamp.upperBound)
        // Sibling ordering: a splitter can never cross the one beside it.
        if let lower = boundary.lowerSibling {
            clamped = max(clamped, self[keyPath: lower] + 0.01)
        }
        if let upper = boundary.upperSibling {
            clamped = min(clamped, self[keyPath: upper] - 0.01)
        }
        return write(boundary, to: clamped)
    }

    /// Stores `fraction` if it differs meaningfully. Returns whether it
    /// did. NaN is impossible here: callers guard non-finite input and
    /// all derived fractions are arithmetic on finite clamped values.
    private mutating func write(_ boundary: GridBoundary, to fraction: CGFloat) -> Bool {
        guard abs(self[keyPath: boundary.fraction] - fraction) > 0.001 else { return false }
        self[keyPath: boundary.fraction] = fraction
        return true
    }

    /// The coupled fractions for resizing a two-thirds window: the dragged
    /// outer edge still honors its own drag clamp, while the hidden inner
    /// divider becomes the midpoint of the resulting span. The inner
    /// divider is derived, not dragged, so its own static clamp and
    /// sibling minimum do not apply; the formulas keep it strictly
    /// between the slot's fixed screen edge and the dragged edge for
    /// every clamped drag.
    private static func twoThirdsSymmetry(
        for slot: Slot, moving boundary: GridBoundary, to raw: CGFloat
    ) -> (dragged: CGFloat, companion: GridBoundary, companionFraction: CGFloat)? {
        let dragged = min(max(raw, boundary.clamp.lowerBound), boundary.clamp.upperBound)
        switch (slot, boundary) {
        case (.sixthsLeftTwoThirds, .sixthsRightSplit):
            // Left two-thirds spans [screen left, R]; line 1 bisects it.
            return (dragged, .sixthsLeftSplit, dragged / 2)
        case (.sixthsRightTwoThirds, .sixthsLeftSplit):
            // Right two-thirds spans [L, screen right]; line 3 bisects it.
            return (dragged, .sixthsRightSplit, (dragged + 1) / 2)
        default:
            return nil
        }
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
    /// The requester is tiled and exactly one window overlaps the target
    /// without leaving a step-aside home (a blocker whose leftover — its
    /// slot minus the target — is exactly one whole slot steps aside
    /// instead): the two swap tiles, the displaced window moves into the
    /// slot the requester vacates; nobody is untiled or restored.
    case swap(displaced: WindowID)
    /// The window already occupies the slot; nothing happens.
    case noop
}

extension TilePlan {
    /// Windows the controller must restore (untile) before committing this
    /// plan.
    ///
    /// `.tile` never names the requester (blockers exclude it by
    /// construction); `.swap` and `.noop` restore nothing.
    func windowsToRestore() -> [WindowID] {
        switch self {
        case .tile(let evicting):
            return evicting
        case .swap, .noop:
            return []
        }
    }
}

/// Pure tiling state: which window occupies which slot, and which layout
/// the canvas is showing. No AppKit, no AX; fully unit-testable.
struct TilingState: Equatable {
    private(set) var occupantBySlot: [Slot: WindowID] = [:]
    /// The layout on screen. Stored, not derived from occupancy: an empty
    /// canvas keeps the user's choice, so the next slot key means the same
    /// position it did before the windows left. `setLayout` is the only
    /// writer, and it refuses a non-empty board: switching is an explicit
    /// canvas action (`TilingSpace.switchLayout`), never a side effect of
    /// a placement.
    private(set) var layout: LayoutKind

    init(layout: LayoutKind = .sixths) {
        self.layout = layout
    }

    /// Adopts `new` on an empty board; the one layout writer. A non-empty
    /// board must be untiled first (the canvas's switch does that), so two
    /// layouts can never coexist on one canvas.
    mutating func setLayout(_ new: LayoutKind) {
        precondition(occupantBySlot.isEmpty, "setLayout requires an empty board")
        layout = new
    }

    func occupant(of slot: Slot) -> WindowID? { occupantBySlot[slot] }

    func slot(of window: WindowID) -> Slot? {
        occupantBySlot.first(where: { $0.value == window })?.key
    }

    /// The slot `key` names in the active layout, or nil when this layout
    /// has no such position.
    func slot(for key: SlotKey) -> Slot? {
        key.slot(in: layout)
    }

    var occupants: [Slot: WindowID] { occupantBySlot }

    var tiledWindows: [WindowID] { Array(Set(occupantBySlot.values)) }

    /// Decides what happens when `window` requests `slot`: the requester
    /// owns `slot` after the move. A tiled requester swaps with a single
    /// overlapping window (the displaced window takes the tile the
    /// requester vacates) — unless that blocker's leftover (its slot
    /// minus the target) is exactly one whole slot, in which case the
    /// plan is an ordinary eviction the commit re-houses: the blocker
    /// steps aside into its own strip instead of trading tiles.
    /// Otherwise every overlapping window is evicted (restored to its
    /// pre-tile frame).
    ///
    /// The target must belong to this canvas's layout: a caller resolves
    /// a `SlotKey` against `layout` first, so a cross-layout request is
    /// unreachable here and is a programming error, not a plan.
    func plan(window: WindowID, into slot: Slot) -> TilePlan {
        precondition(slot.layout == layout, "plan target must match the stored layout")
        if occupantBySlot[slot] == window { return .noop }
        let blockers = occupantBySlot
            .filter { $0.value != window && $0.key.overlaps(slot) }
            .map(\.value)
            .sorted()
        // Tile swap: the requester offers its own tile, so a single
        // window in the way can take it instead of losing its tiling.
        // The vacated tile must not overlap the target (the displaced
        // window would land inside the requester's new tile), and more
        // than one blocker (or an untiled requester with no tile to
        // offer) falls back to eviction. A blocker whose leftover (its
        // slot minus the target) is a clean whole slot steps aside
        // instead — nearer, and the requester's vacated tile frees up
        // for reflow — so the swap only stands when no such home exists.
        if blockers.count == 1, let previous = self.slot(of: window),
            !previous.overlaps(slot),
            stepAsideHome(evictee: blockers[0], for: slot) == nil
        {
            return .swap(displaced: blockers[0])
        }
        return .tile(evicting: blockers)
    }

    /// Commit a planned placement. Evicted windows must already be removed
    /// via `remove(window:)`. Claiming an occupied slot evicts its
    /// occupant from state (the gateway write decides the truth on
    /// screen; callers roll back on refusal, as `place` does).
    mutating func commit(window: WindowID, into slot: Slot) {
        precondition(slot.layout == layout, "commit target must match the stored layout")
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

    /// The step-aside home: when `evictee`'s slot overlaps `target` and
    /// its leftover (its slot minus the target) is exactly one whole
    /// slot of the target's layout that no other occupant holds, that
    /// slot is where the blocker steps aside (the left third requested
    /// at its top sixth steps down into the bottom-left sixth; the one
    /// overlap that is not a containment — a left two-thirds blocking a
    /// right two-thirds request — steps aside into the left third).
    /// Shared by `plan`, where a step-aside overrides a swap, and
    /// `rehousingHome`, so the plan and the commit can never disagree
    /// about whether one exists.
    private func stepAsideHome(evictee: WindowID, for target: Slot) -> Slot? {
        guard let current = slot(of: evictee), current.overlaps(target) else { return nil }
        let leftover = current.cells.subtracting(target.cells)
        guard leftover.count < current.cells.count,
            let aside = Slot.allCases.first(where: {
                $0.layout == target.layout && $0.cells == leftover
            }),
            !occupantBySlot.contains(where: { occupant in
                occupant.value != evictee && !occupant.key.cells.isDisjoint(with: leftover)
            })
        else { return nil }
        return aside
    }

    /// The slot a lone evicted window can move into instead of losing
    /// its tiling. Two rules, both exact-or-nil — there is no
    /// unambiguous home to guess, so a near miss leaves the eviction
    /// untouched and the window untiles to its pre-tile frame:
    ///
    /// - Step-aside: see `stepAsideHome`. Checked first:
    ///   it keeps the evictee adjacent to the request.
    /// - Free region: once the requester takes `target`, the cells left
    ///   free form a region; when that region is exactly one whole slot
    ///   of the target's layout, the evictee re-tiles into it (the
    ///   middle third making room for the right two-thirds moves into
    ///   the free top-left sixth). The region may include cells that
    ///   were free before the request: the evictee has nowhere else to
    ///   go, and a whole free slot is a whole free slot.
    ///
    /// A caller that omits `previous` computes the pre-request region
    /// for the free-region rule, which is only correct for an untiled
    /// requester. (The step-aside rule ignores `previous`: a requester
    /// whose vacated slot reached the evictee's leftover would have to
    /// span both target and leftover — the evictee's own slot.)
    func rehousingHome(
        evicting evictee: WindowID, for target: Slot, vacating previous: Slot? = nil
    ) -> Slot? {
        if let aside = stepAsideHome(evictee: evictee, for: target) { return aside }
        guard let current = slot(of: evictee), current.overlaps(target) else { return nil }
        // Free region: the free region is the one the request leaves
        // behind: the target is taken by the requester, the evictee's
        // own slot is freed, and the requester's vacated slot is freed
        // too (it is still committed here).
        var occupied = target.cells
        for (slot, window) in occupantBySlot
        where window != evictee && slot != previous {
            occupied.formUnion(slot.cells)
        }
        let free = Set(TileCell.allCases).subtracting(occupied)
        return Slot.allCases.first { $0.layout == target.layout && $0.cells == free }
    }

    /// Reflow: decides which survivors absorb freed cells. When a tiled
    /// window leaves the layout (eviction, untile, drag-out, close) or
    /// moves, its freed cells merge with exactly one adjacent survivor
    /// into a whole slot, and that survivor grows into it — the top-left
    /// sixth whose bottom mate left becomes the left third, the right
    /// third beside a freed middle third becomes the right two-thirds.
    ///
    /// Call after the window left the state: `freed` is what its slot
    /// (or slot-minus-target, for a move) contributed, and every cell
    /// still occupied — the requester's fresh tile included — blocks
    /// every candidate. Exact-or-empty: a candidate's cells plus the
    /// freed cells must form exactly one slot of the survivor's layout,
    /// so reflow never grabs space nobody freed and never crosses
    /// another window. A hole no survivor merges into exactly stays a
    /// hole. One merge can ever apply per pass (every merge covers the
    /// whole freed region, so two would overlap); the loop re-runs only
    /// as cascade safety.
    ///
    /// `excluding` names windows that never grow: the requester that
    /// just chose its slot (or it would absorb its own freed cells and
    /// undo the move) and expanded windows (callers keep them covering
    /// the layout). Ties — both third flanks merging into competing
    /// two-thirds — prefer the right: the candidate whose grown slot
    /// reaches furthest right wins, then the larger slot, then slot
    /// declaration order for total determinism.
    ///
    /// Returns the placements (window -> grown slot); callers commit them
    /// and write the frames, rolling back on refusal so state and screen
    /// never disagree about who holds the freed cells.
    func reflow(freed freedCells: Set<TileCell>, excluding: Set<WindowID> = [])
        -> [WindowID: Slot]
    {
        var freed = freedCells
        var occupants = occupantBySlot
        // Cells still occupied are not free, whatever the caller passed;
        // the requester's fresh tile blocks like any other window's.
        freed.subtract(occupantBySlot.keys.flatMap { $0.cells })
        for (slot, window) in occupantBySlot where excluding.contains(window) {
            occupants[slot] = nil
        }
        var placements: [WindowID: Slot] = [:]
        while !freed.isEmpty {
            // The rightmost mergeable survivor: grown slot reaching
            // furthest right wins, then larger, then declaration order.
            let best = occupants
                .compactMap { (slot: Slot, window: WindowID) -> (Slot, WindowID, Slot)? in
                    let union = slot.cells.union(freed)
                    guard
                        let grown = Slot.allCases.first(where: {
                            $0.layout == slot.layout && $0.cells == union
                        })
                    else { return nil }
                    return (slot, window, grown)
                }
                .max { lhs, rhs in
                    let left = lhs.2.geometry, right = rhs.2.geometry
                    if left.columns.upperBound != right.columns.upperBound {
                        return left.columns.upperBound < right.columns.upperBound
                    }
                    if lhs.2.cells.count != rhs.2.cells.count {
                        return lhs.2.cells.count < rhs.2.cells.count
                    }
                    // Unreachable in practice (a grown slot determines
                    // its window exactly), but total for determinism.
                    let leftIndex = Slot.allCases.firstIndex(of: lhs.2) ?? 0
                    let rightIndex = Slot.allCases.firstIndex(of: rhs.2) ?? 0
                    return leftIndex > rightIndex
                }
            guard let (from, window, grown) = best else { break }
            placements[window] = grown
            occupants[from] = nil
            occupants[grown] = window
            freed.subtract(grown.cells)
        }
        return placements
    }
}
