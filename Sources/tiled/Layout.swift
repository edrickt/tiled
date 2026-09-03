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

    /// Fixed rect within the given bounds (a screen's visible frame, AppKit coordinates).
    /// Note: AppKit y grows upward, so `minY` is the BOTTOM of the bounds.
    func rect(in bounds: CGRect) -> CGRect {
        let w = bounds.width / 2
        let h = bounds.height / 2
        return switch self {
        case .topLeft:
            CGRect(x: bounds.minX, y: bounds.midY, width: w, height: h)
        case .topRight:
            CGRect(x: bounds.midX, y: bounds.midY, width: w, height: h)
        case .bottomLeft:
            CGRect(x: bounds.minX, y: bounds.minY, width: w, height: h)
        case .bottomRight:
            CGRect(x: bounds.midX, y: bounds.minY, width: w, height: h)
        case .leftHalf:
            CGRect(x: bounds.minX, y: bounds.minY, width: w, height: bounds.height)
        case .rightHalf:
            CGRect(x: bounds.midX, y: bounds.minY, width: w, height: bounds.height)
        }
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
