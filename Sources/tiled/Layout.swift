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

/// A tile a window can occupy.
///
/// Overlap rule: two slots overlap iff their cell sets intersect.
/// The controller enforces "one window per tile" via the eviction/swap rules in
/// `TilingState.plan(window:into:)`.
///
/// Quarters slots tile the screen as 2x2 quads plus full-column halves.
/// Sixths slots tile it as a 3x2 grid (corner/middle sixths) plus full-height
/// thirds and two-thirds. Quads and sixths are both unions of `TileCell`s, so
/// cross-layout overlap falls out of the same cell-set intersection.
enum Slot: String, CaseIterable {
    // Quarters
    case topLeft, topRight, bottomLeft, bottomRight
    case leftHalf, rightHalf
    // Sixths: corners, middles, thirds, two-thirds
    case sixthTopLeft, sixthTopMiddle, sixthTopRight
    case sixthBottomLeft, sixthBottomMiddle, sixthBottomRight
    case sixthLeft, sixthMiddle, sixthRight
    case sixthsLeftTwoThirds, sixthsRightTwoThirds

    /// Which layout this slot belongs to.
    var layout: LayoutKind {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight, .leftHalf, .rightHalf:
            .quarters
        case .sixthTopLeft, .sixthTopMiddle, .sixthTopRight,
            .sixthBottomLeft, .sixthBottomMiddle, .sixthBottomRight,
            .sixthLeft, .sixthMiddle, .sixthRight,
            .sixthsLeftTwoThirds, .sixthsRightTwoThirds:
            .sixths
        }
    }

    /// The cells this slot covers.
    var cells: Set<TileCell> {
        switch self {
        case .topLeft: [.col0Top, .col1Top]
        case .topRight: [.col2Top, .col3Top]
        case .bottomLeft: [.col0Bottom, .col1Bottom]
        case .bottomRight: [.col2Bottom, .col3Bottom]
        case .leftHalf: [.col0Top, .col1Top, .col0Bottom, .col1Bottom]
        case .rightHalf: [.col2Top, .col3Top, .col2Bottom, .col3Bottom]
        case .sixthTopLeft: [.col0Top]
        case .sixthTopMiddle: [.col1Top, .col2Top]
        case .sixthTopRight: [.col3Top]
        case .sixthBottomLeft: [.col0Bottom]
        case .sixthBottomMiddle: [.col1Bottom, .col2Bottom]
        case .sixthBottomRight: [.col3Bottom]
        case .sixthLeft: [.col0Top, .col0Bottom]
        case .sixthMiddle: [.col1Top, .col2Top, .col1Bottom, .col2Bottom]
        case .sixthRight: [.col3Top, .col3Bottom]
        case .sixthsLeftTwoThirds: [.col0Top, .col1Top, .col2Top, .col0Bottom, .col1Bottom, .col2Bottom]
        case .sixthsRightTwoThirds: [.col1Top, .col2Top, .col3Top, .col1Bottom, .col2Bottom, .col3Bottom]
        }
    }

    func overlaps(_ other: Slot) -> Bool {
        !cells.isDisjoint(with: other.cells)
    }

    // MARK: Presentation

    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .sixthTopLeft: "Top Left Sixth"
        case .sixthTopMiddle: "Top Middle Sixth"
        case .sixthTopRight: "Top Right Sixth"
        case .sixthBottomLeft: "Bottom Left Sixth"
        case .sixthBottomMiddle: "Bottom Middle Sixth"
        case .sixthBottomRight: "Bottom Right Sixth"
        case .sixthLeft: "Left Sixth"
        case .sixthMiddle: "Middle Sixth"
        case .sixthRight: "Right Sixth"
        case .sixthsLeftTwoThirds: "Left Two Sixths"
        case .sixthsRightTwoThirds: "Right Two Sixths"
        }
    }

    var hotkeyLabel: String {
        switch self {
        case .topLeft: "⌥⇧U"
        case .topRight: "⌥⇧O"
        case .bottomLeft: "⌥⇧M"
        case .bottomRight: "⌥⇧."
        case .leftHalf: "⌥⇧J"
        case .rightHalf: "⌥⇧L"
        case .sixthTopLeft: "⌥⇧⌘U"
        case .sixthTopMiddle: "⌥⇧⌘I"
        case .sixthTopRight: "⌥⇧⌘O"
        case .sixthBottomLeft: "⌥⇧⌘M"
        case .sixthBottomMiddle: "⌥⇧⌘,"
        case .sixthBottomRight: "⌥⇧⌘."
        case .sixthLeft: "⌥⇧⌘J"
        case .sixthMiddle: "⌥⇧⌘K"
        case .sixthRight: "⌥⇧⌘L"
        case .sixthsLeftTwoThirds: "⌥⇧⌘H"
        case .sixthsRightTwoThirds: "⌥⇧⌘;"
        }
    }
}

extension Slot {
    /// Plain-text hotkey reference for the Shortcuts window. Derived from
    /// the same titles and labels as the status menu, so the three can
    /// never disagree about what a shortcut does.
    static var cheatsheetText: String {
        var lines = [
            "Tile the focused window. Tiling a window",
            "into its own tile does nothing.",
            "",
        ]
        for layout in [LayoutKind.quarters, LayoutKind.sixths] as [LayoutKind] {
            lines.append(layout == .quarters ? "Quarters — hold ⌥⇧" : "Sixths — hold ⌥⇧⌘")
            for slot in Slot.allCases where slot.layout == layout {
                lines.append("\(slot.hotkeyLabel)\t\(slot.title)")
            }
            lines.append("")
        }
        lines.append("Drag a tiled window's edge to resize it —")
        lines.append("neighbors sharing the edge follow.")
        return lines.joined(separator: "\n")
    }
}

/// An edge of a window's frame.
enum TileEdge: CaseIterable {
    case left, right, top, bottom
}

/// A movable boundary in the grid. Screen edges are fixed, not boundaries.
enum GridBoundary: CaseIterable {
    case columnSplit // vertical divider between left and right columns
    case leftRowSplit // horizontal divider for the left column only
    case rightRowSplit // horizontal divider for the right column only
    case sixthsLeftSplit // vertical divider between the left and middle thirds
    case sixthsRightSplit // vertical divider between the middle and right thirds
    case sixthsLeftRowSplit // horizontal divider for the left third only
    case sixthsMiddleRowSplit // horizontal divider for the middle third only
    case sixthsRightRowSplit // horizontal divider for the right third only
}

/// The tile grid geometry: splitter fractions over a screen's visible frame.
/// Every occupied slot's rect derives from these.
///
/// Quarters: the vertical divider is shared by both rows; each column has
/// its own independent horizontal divider:
/// - Dragging right half's left edge -> columnSplit -> both left windows resize.
/// - Dragging BL's right edge -> columnSplit -> right side shrinks, TL grows.
/// - Dragging BL's top edge -> leftRowSplit -> TL shrinks vertically, right
///   column unaffected (and symmetrically, BR's top edge -> rightRowSplit).
///
/// Sixths: two vertical dividers (default 1/3, 2/3); each third has its own
/// independent horizontal divider (default 1/2 each), mirroring quarters'
/// per-column row splits: dragging one column's row edge resizes only that
/// column's corners. The layouts' splitters are independent: dragging
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

    /// Which grid boundary an edge of `slot` corresponds to.
    /// nil = screen edge (fixed, cannot be dragged).
    static func boundary(edge: TileEdge, slot: Slot) -> GridBoundary? {
        switch (slot, edge) {
        case (.topLeft, .right), (.bottomLeft, .right), (.leftHalf, .right),
            (.topRight, .left), (.bottomRight, .left), (.rightHalf, .left):
            return .columnSplit
        case (.topLeft, .bottom), (.bottomLeft, .top):
            return .leftRowSplit
        case (.topRight, .bottom), (.bottomRight, .top):
            return .rightRowSplit
        // Sixths thirds dividers (shared across rows):
        // - left/middle boundary: right edge of the left third,
        //   left edge of the middle third and of the right two-thirds.
        case (.sixthTopLeft, .right), (.sixthBottomLeft, .right),
            (.sixthLeft, .right),
            (.sixthTopMiddle, .left), (.sixthBottomMiddle, .left),
            (.sixthMiddle, .left), (.sixthsRightTwoThirds, .left):
            return .sixthsLeftSplit
        // - middle/right boundary: right edge of the middle third and of the
        //   left two-thirds, left edge of the right third.
        case (.sixthTopMiddle, .right), (.sixthBottomMiddle, .right),
            (.sixthMiddle, .right), (.sixthsLeftTwoThirds, .right),
            (.sixthTopRight, .left), (.sixthBottomRight, .left),
            (.sixthRight, .left):
            return .sixthsRightSplit
        // Sixths row dividers (one per column, like quarters).
        case (.sixthTopLeft, .bottom), (.sixthBottomLeft, .top):
            return .sixthsLeftRowSplit
        case (.sixthTopMiddle, .bottom), (.sixthBottomMiddle, .top):
            return .sixthsMiddleRowSplit
        case (.sixthTopRight, .bottom), (.sixthBottomRight, .top):
            return .sixthsRightRowSplit
        // Screen edges are fixed (every remaining pair).
        case (.topLeft, .left), (.topLeft, .top),
            (.topRight, .right), (.topRight, .top),
            (.bottomLeft, .left), (.bottomLeft, .bottom),
            (.bottomRight, .right), (.bottomRight, .bottom),
            (.leftHalf, .left), (.leftHalf, .top), (.leftHalf, .bottom),
            (.rightHalf, .right), (.rightHalf, .top), (.rightHalf, .bottom),
            (.sixthTopLeft, .left), (.sixthTopLeft, .top),
            (.sixthTopMiddle, .top),
            (.sixthTopRight, .right), (.sixthTopRight, .top),
            (.sixthBottomLeft, .left), (.sixthBottomLeft, .bottom),
            (.sixthBottomMiddle, .bottom),
            (.sixthBottomRight, .right), (.sixthBottomRight, .bottom),
            (.sixthLeft, .left), (.sixthLeft, .top), (.sixthLeft, .bottom),
            (.sixthMiddle, .top), (.sixthMiddle, .bottom),
            (.sixthRight, .right), (.sixthRight, .top), (.sixthRight, .bottom),
            (.sixthsLeftTwoThirds, .left), (.sixthsLeftTwoThirds, .top),
            (.sixthsLeftTwoThirds, .bottom),
            (.sixthsRightTwoThirds, .right), (.sixthsRightTwoThirds, .top),
            (.sixthsRightTwoThirds, .bottom):
            return nil
        }
    }

    /// The screen-space position of a boundary within `bounds` (AppKit coords).
    func position(of boundary: GridBoundary, in bounds: CGRect) -> CGFloat {
        switch boundary {
        case .columnSplit:
            bounds.minX + columnSplit * bounds.width
        case .leftRowSplit:
            bounds.minY + leftRowSplit * bounds.height
        case .rightRowSplit:
            bounds.minY + rightRowSplit * bounds.height
        case .sixthsLeftSplit:
            bounds.minX + sixthsLeftSplit * bounds.width
        case .sixthsRightSplit:
            bounds.minX + sixthsRightSplit * bounds.width
        case .sixthsLeftRowSplit:
            bounds.minY + sixthsLeftRowSplit * bounds.height
        case .sixthsMiddleRowSplit:
            bounds.minY + sixthsMiddleRowSplit * bounds.height
        case .sixthsRightRowSplit:
            bounds.minY + sixthsRightRowSplit * bounds.height
        }
    }

    /// Moves a boundary to an absolute screen-space position (clamped).
    /// Returns true if the value changed meaningfully.
    @discardableResult
    mutating func update(
        boundary: GridBoundary, toPosition position: CGFloat, in bounds: CGRect
    ) -> Bool {
        switch boundary {
        case .columnSplit:
            let clamped = min(
                max((position - bounds.minX) / bounds.width, Self.columnClamp.lowerBound),
                Self.columnClamp.upperBound)
            guard abs(clamped - columnSplit) > 0.001 else { return false }
            columnSplit = clamped
            return true
        case .leftRowSplit:
            let clamped = Self.clampedRowSplit(toPosition: position, in: bounds)
            guard abs(clamped - leftRowSplit) > 0.001 else { return false }
            leftRowSplit = clamped
            return true
        case .rightRowSplit:
            let clamped = Self.clampedRowSplit(toPosition: position, in: bounds)
            guard abs(clamped - rightRowSplit) > 0.001 else { return false }
            rightRowSplit = clamped
            return true
        case .sixthsLeftSplit:
            // Ordering guard: the left divider can never cross the right
            // one, so a wild drag clamps against the sibling instead of
            // inverting the middle third (and symmetrically below).
            var clamped = Self.clampedSixthsColumn(toPosition: position, in: bounds)
            clamped = min(clamped, sixthsRightSplit - 0.01)
            guard abs(clamped - sixthsLeftSplit) > 0.001 else { return false }
            sixthsLeftSplit = clamped
            return true
        case .sixthsRightSplit:
            var clamped = Self.clampedSixthsColumn(toPosition: position, in: bounds)
            clamped = max(clamped, sixthsLeftSplit + 0.01)
            guard abs(clamped - sixthsRightSplit) > 0.001 else { return false }
            sixthsRightSplit = clamped
            return true
        case .sixthsLeftRowSplit:
            let clamped = Self.clampedRowSplit(toPosition: position, in: bounds)
            guard abs(clamped - sixthsLeftRowSplit) > 0.001 else { return false }
            sixthsLeftRowSplit = clamped
            return true
        case .sixthsMiddleRowSplit:
            let clamped = Self.clampedRowSplit(toPosition: position, in: bounds)
            guard abs(clamped - sixthsMiddleRowSplit) > 0.001 else { return false }
            sixthsMiddleRowSplit = clamped
            return true
        case .sixthsRightRowSplit:
            let clamped = Self.clampedRowSplit(toPosition: position, in: bounds)
            guard abs(clamped - sixthsRightRowSplit) > 0.001 else { return false }
            sixthsRightRowSplit = clamped
            return true
        }
    }

    private static func clampedSixthsColumn(toPosition position: CGFloat, in bounds: CGRect) -> CGFloat {
        min(
            max(
                (position - bounds.minX) / bounds.width,
                Self.sixthsColumnClamp.lowerBound),
            Self.sixthsColumnClamp.upperBound)
    }

    private static func clampedRowSplit(toPosition position: CGFloat, in bounds: CGRect) -> CGFloat {
        min(
            max((position - bounds.minY) / bounds.height, Self.rowClamp.lowerBound),
            Self.rowClamp.upperBound)
    }

    /// Rect for `slot` within `bounds` (AppKit coordinates, y grows upward).
    ///
    /// Quarters rects derive from the quarters splitters; sixths rects from
    /// the sixths splitters (defaults 1/3, 2/3, 1/2).
    func rect(for slot: Slot, in bounds: CGRect) -> CGRect {
        let x = position(of: .columnSplit, in: bounds)
        let leftRowY = position(of: .leftRowSplit, in: bounds)
        let rightRowY = position(of: .rightRowSplit, in: bounds)
        let x13 = position(of: .sixthsLeftSplit, in: bounds)
        let x23 = position(of: .sixthsRightSplit, in: bounds)
        let leftMidY = position(of: .sixthsLeftRowSplit, in: bounds)
        let middleMidY = position(of: .sixthsMiddleRowSplit, in: bounds)
        let rightMidY = position(of: .sixthsRightRowSplit, in: bounds)
        return switch slot {
        case .leftHalf:
            CGRect(x: bounds.minX, y: bounds.minY, width: x - bounds.minX, height: bounds.height)
        case .rightHalf:
            CGRect(x: x, y: bounds.minY, width: bounds.maxX - x, height: bounds.height)
        case .topLeft:
            CGRect(
                x: bounds.minX, y: leftRowY, width: x - bounds.minX,
                height: bounds.maxY - leftRowY)
        case .bottomLeft:
            CGRect(
                x: bounds.minX, y: bounds.minY, width: x - bounds.minX,
                height: leftRowY - bounds.minY)
        case .topRight:
            CGRect(
                x: x, y: rightRowY, width: bounds.maxX - x, height: bounds.maxY - rightRowY)
        case .bottomRight:
            CGRect(
                x: x, y: bounds.minY, width: bounds.maxX - x, height: rightRowY - bounds.minY)
        case .sixthTopLeft:
            CGRect(x: bounds.minX, y: leftMidY, width: x13 - bounds.minX, height: bounds.maxY - leftMidY)
        case .sixthTopMiddle:
            CGRect(x: x13, y: middleMidY, width: x23 - x13, height: bounds.maxY - middleMidY)
        case .sixthTopRight:
            CGRect(x: x23, y: rightMidY, width: bounds.maxX - x23, height: bounds.maxY - rightMidY)
        case .sixthBottomLeft:
            CGRect(x: bounds.minX, y: bounds.minY, width: x13 - bounds.minX, height: leftMidY - bounds.minY)
        case .sixthBottomMiddle:
            CGRect(x: x13, y: bounds.minY, width: x23 - x13, height: middleMidY - bounds.minY)
        case .sixthBottomRight:
            CGRect(x: x23, y: bounds.minY, width: bounds.maxX - x23, height: rightMidY - bounds.minY)
        case .sixthLeft:
            CGRect(x: bounds.minX, y: bounds.minY, width: x13 - bounds.minX, height: bounds.height)
        case .sixthMiddle:
            CGRect(x: x13, y: bounds.minY, width: x23 - x13, height: bounds.height)
        case .sixthRight:
            CGRect(x: x23, y: bounds.minY, width: bounds.maxX - x23, height: bounds.height)
        case .sixthsLeftTwoThirds:
            CGRect(x: bounds.minX, y: bounds.minY, width: x23 - bounds.minX, height: bounds.height)
        case .sixthsRightTwoThirds:
            CGRect(x: x13, y: bounds.minY, width: bounds.maxX - x13, height: bounds.height)
        }
    }
}

/// Opaque window handle used by the pure layout state.
/// The controller maps these to live AXUIElements.
typealias WindowID = Int

/// What the controller should do for a tiling request.
enum TilePlan: Equatable {
    /// Place the window; the listed windows must be untiled (restored) first.
    case tile(evicting: [WindowID])
    /// Exchange places: every listed window moves to its slot, nobody is
    /// untiled. Always includes the requesting window -> the target slot.
    case swap(placements: [WindowID: Slot])
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
    /// the requester itself when it is already tiled — but the requester
    /// is moving, not being evicted: its old tile is vacated by the
    /// subsequent commit, and its record (and pre-tile frame) must survive
    /// until `place` runs. Restoring it first would delete its record, so
    /// `place` would bail and the window would merely untile instead of
    /// landing in its new tile. `.tile` never names the requester
    /// (blockers exclude it by construction), so the filter is a no-op
    /// there; `.swap`/`.noop` restore nothing.
    func windowsToRestore(requester: WindowID) -> [WindowID] {
        switch self {
        case .tile(let evicting), .switchLayout(let evicting):
            return evicting.filter { $0 != requester }
        case .swap, .noop:
            return []
        }
    }
}

/// Pure tiling state: which window occupies which slot.
/// No AppKit, no AX — fully unit-testable.
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

    /// Decides what happens when `window` requests `slot`.
    ///
    /// Rules (as decided):
    /// - Same window already in the slot -> no-op.
    /// - Request in a different layout than the active one -> reset: evict
    ///   every tiled window, switch layouts, place the requester.
    /// - Same layout, no overlap with other windows -> plain tile. A tiled
    ///   window moves to the new slot; it never evicts itself.
    /// - Same layout, overlap with other windows -> swap if there is room,
    ///   else evict. When the requesting window is already tiled and every
    ///   overlapping window fits into the footprint it vacates, they
    ///   exchange places and nobody is untiled (TL -> occupied BR swaps the
    ///   two windows; LeftHalf -> occupied TR swaps half and quad).
    ///   Otherwise the overlapping windows are evicted: e.g. with all four
    ///   quads tiled, TL -> RightHalf overlaps two windows while vacating
    ///   one quad, so both are evicted instead of swapped. An untiled
    ///   requester vacates nothing, so it always evicts.
    func plan(window: WindowID, into slot: Slot) -> TilePlan {
        if occupantBySlot[slot] == window { return .noop }
        if !occupantBySlot.isEmpty, slot.layout != activeLayout {
            return .switchLayout(evicting: tiledWindows.sorted())
        }
        var blockers: [(slot: Slot, window: WindowID)] = []
        for (occupied, occupant) in occupantBySlot
        where occupant != window && occupied.overlaps(slot) {
            blockers.append((occupied, occupant))
        }
        guard !blockers.isEmpty else { return .tile(evicting: []) }
        if let old = self.slot(of: window),
            let relocation = Self.relocate(
                blockers: blockers.map(\.window).sorted(),
                within: old.cells.subtracting(slot.cells),
                layout: slot.layout)
        {
            var placements = relocation
            placements[window] = slot
            return .swap(placements: placements)
        }
        return .tile(evicting: blockers.map(\.window).sorted())
    }

    /// Assigns each blocker a distinct slot inside `free` (cells vacated by
    /// the requesting window, minus its target), restricted to the target's
    /// layout, preferring larger slots so halves stay halves when possible.
    /// Returns nil when there isn't enough space to accommodate everyone.
    private static func relocate(blockers: [WindowID], within free: Set<TileCell>, layout: LayoutKind)
        -> [WindowID: Slot]?
    {
        let bySize = Slot.allCases.filter {
            $0.layout == layout && $0.cells.isSubset(of: free)
        }.sorted {
            if $0.cells.count != $1.cells.count { return $0.cells.count > $1.cells.count }
            return Slot.allCases.firstIndex(of: $0)! < Slot.allCases.firstIndex(of: $1)!
        }
        var assigned: [WindowID: Slot] = [:]
        var used: Set<TileCell> = []
        func search(_ index: Int) -> Bool {
            guard index < blockers.count else { return true }
            for candidate in bySize where candidate.cells.isDisjoint(with: used) {
                assigned[blockers[index]] = candidate
                used.formUnion(candidate.cells)
                if search(index + 1) { return true }
                used.subtract(candidate.cells)
                assigned[blockers[index]] = nil
            }
            return false
        }
        return search(0) ? assigned : nil
    }

    /// Commit a multi-window exchange. Removals happen before placements so
    /// overlapping targets (e.g. a blocker taking the requester's old slot)
    /// never clobber each other.
    mutating func commitSwaps(_ placements: [WindowID: Slot]) {
        for window in placements.keys {
            remove(window: window)
        }
        for (window, slot) in placements {
            occupantBySlot[slot] = window
        }
    }

    /// Commit a planned placement. Evicted windows must already be removed
    /// via `remove(window:)`.
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
