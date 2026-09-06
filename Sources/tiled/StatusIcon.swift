/// Pure mapping from tiling state to the menu-bar glyph's filled cells.
///
/// The status icon is a live occupancy map, not just a layout badge: each
/// icon cell renders solid only while a tiled window actually covers that
/// spot, dimmed solid otherwise. Quarters draws its four quads; sixths draws its
/// six corners. Larger slots light every icon cell they cover (a half
/// fills its whole column; a third fills its whole column; a two-thirds
/// fills two columns), and occupancy is cell overlap rather than slot
/// identity, so a transient mixed state never reads as empty.
///
/// AppKit-free so the mapping is unit-testable; `AppDelegate` draws the
/// snapshot this produces.
enum StatusIcon {
    /// What the icon currently depicts: layout geometry plus fill. The
    /// delegate diffs this to redraw on occupancy changes, not just
    /// layout switches — windows coming and going within one layout must
    /// flip cells without the layout moving.
    struct Snapshot: Equatable {
        var layout: LayoutKind
        /// Icon cells (members of `cells(for:)`), in icon order, that are
        /// currently covered by a tiled window.
        var filled: [Slot]
    }

    /// The icon cells for a layout, in drawing order (left to right, top
    /// to bottom): the four quads for quarters, the six corners for sixths.
    static func cells(for layout: LayoutKind) -> [Slot] {
        switch layout {
        case .quarters:
            [.topLeft, .topRight, .bottomLeft, .bottomRight]
        case .sixths:
            [
                .sixthTopLeft, .sixthTopMiddle, .sixthTopRight,
                .sixthBottomLeft, .sixthBottomMiddle, .sixthBottomRight,
            ]
        }
    }

    /// Which icon cells of `layout` are covered by `occupants`, in icon
    /// order. A cell lights when any occupant's cells intersect it —
    /// halves, thirds, and two-thirds light every cell they span, and a
    /// squatter from the other layout still lights the cells it touches.
    static func filledCells(
        layout: LayoutKind, occupants: [Slot: WindowID]
    ) -> [Slot] {
        cells(for: layout).filter { cell in
            occupants.keys.contains { $0.overlaps(cell) }
        }
    }

    /// One immutable pass over the state the icon reads: geometry plus
    /// fill, so the delegate diffs a single value.
    static func snapshot(
        layout: LayoutKind, occupants: [Slot: WindowID]
    ) -> Snapshot {
        Snapshot(layout: layout, filled: filledCells(layout: layout, occupants: occupants))
    }
}
