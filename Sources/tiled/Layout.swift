import CoreGraphics

/// The four quadrants of a screen.
enum Quad: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
}

/// A tile a window can occupy. Quads cover one quadrant; halves span a full column.
///
/// Overlap rule: two slots overlap iff their quad sets intersect.
/// The controller enforces "one window per tile" via the eviction rules in
/// `TilingState.plan(window:into:)`.
enum Slot: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    case leftHalf, rightHalf

    /// The quadrants this slot covers.
    var quads: Set<Quad> {
        switch self {
        case .topLeft: [.topLeft]
        case .topRight: [.topRight]
        case .bottomLeft: [.bottomLeft]
        case .bottomRight: [.bottomRight]
        case .leftHalf: [.topLeft, .bottomLeft]
        case .rightHalf: [.topRight, .bottomRight]
        }
    }

    func overlaps(_ other: Slot) -> Bool {
        !quads.isDisjoint(with: other.quads)
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
        }
    }
}

/// An edge of a window's frame.
enum TileEdge: CaseIterable {
    case left, right, top, bottom
}

/// A movable boundary in the grid. Screen edges are fixed, not boundaries.
enum GridBoundary: CaseIterable {
    case columnSplit // vertical divider between left and right columns
    case rowSplit // horizontal divider shared by both columns
}

/// The tile grid geometry: three splitter fractions over a screen's visible
/// frame. Every occupied slot's rect derives from these.
///
/// All example behaviors from the design derive from this model:
/// - Dragging right half's left edge -> columnSplit -> both left windows resize.
/// - Dragging BL's right edge -> columnSplit -> right side shrinks, TL grows.
/// - Dragging BL's top edge -> leftRowSplit -> TL shrinks vertically.
struct GridLayout: Equatable {
    /// Fraction of width where the left column ends.
    var columnSplit: CGFloat = 0.5
    /// Fraction of height where the row divider sits (shared by both columns:
    /// the model is a 2×2 grid, so there is exactly one horizontal divider).
    var rowSplit: CGFloat = 0.5

    static let columnClamp: ClosedRange<CGFloat> = 0.15...0.85
    static let rowClamp: ClosedRange<CGFloat> = 0.2...0.8

    /// Which grid boundary an edge of `slot` corresponds to.
    /// nil = screen edge (fixed, cannot be dragged).
    static func boundary(edge: TileEdge, slot: Slot) -> GridBoundary? {
        switch (slot, edge) {
        case (.topLeft, .right), (.bottomLeft, .right), (.leftHalf, .right),
            (.topRight, .left), (.bottomRight, .left), (.rightHalf, .left):
            return .columnSplit
        case (.topLeft, .bottom), (.bottomLeft, .top),
            (.topRight, .bottom), (.bottomRight, .top):
            return .rowSplit
        default:
            return nil // screen edges
        }
    }

    /// The screen-space position of a boundary within `bounds` (AppKit coords).
    func position(of boundary: GridBoundary, in bounds: CGRect) -> CGFloat {
        switch boundary {
        case .columnSplit:
            bounds.minX + columnSplit * bounds.width
        case .rowSplit:
            bounds.minY + rowSplit * bounds.height
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
        case .rowSplit:
            let clamped = min(
                max((position - bounds.minY) / bounds.height, Self.rowClamp.lowerBound),
                Self.rowClamp.upperBound)
            guard abs(clamped - rowSplit) > 0.001 else { return false }
            rowSplit = clamped
            return true
        }
    }

    /// Rect for `slot` within `bounds` (AppKit coordinates, y grows upward).
    func rect(for slot: Slot, in bounds: CGRect) -> CGRect {
        let x = position(of: .columnSplit, in: bounds)
        let rowY = position(of: .rowSplit, in: bounds)
        return switch slot {
        case .leftHalf:
            CGRect(x: bounds.minX, y: bounds.minY, width: x - bounds.minX, height: bounds.height)
        case .rightHalf:
            CGRect(x: x, y: bounds.minY, width: bounds.maxX - x, height: bounds.height)
        case .topLeft:
            CGRect(
                x: bounds.minX, y: rowY, width: x - bounds.minX,
                height: bounds.maxY - rowY)
        case .bottomLeft:
            CGRect(
                x: bounds.minX, y: bounds.minY, width: x - bounds.minX,
                height: rowY - bounds.minY)
        case .topRight:
            CGRect(
                x: x, y: rowY, width: bounds.maxX - x, height: bounds.maxY - rowY)
        case .bottomRight:
            CGRect(
                x: x, y: bounds.minY, width: bounds.maxX - x, height: rowY - bounds.minY)
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
    /// The window already occupies the slot; untile it (toggle).
    case untile
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

    /// Decides what happens when `window` requests `slot`.
    ///
    /// Rules (as decided):
    /// - Same window already in the slot -> toggle off.
    /// - Otherwise, evict every window occupying any slot that overlaps the target.
    ///   (Half over two quads evicts both; quad over a half evicts the half.)
    /// - A window requesting a different overlapping slot moves; it never evicts itself.
    func plan(window: WindowID, into slot: Slot) -> TilePlan {
        if occupantBySlot[slot] == window { return .untile }
        var evicting = Set<WindowID>()
        for (occupied, occupant) in occupantBySlot
        where occupant != window && occupied.overlaps(slot) {
            evicting.insert(occupant)
        }
        return .tile(evicting: evicting.sorted())
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
