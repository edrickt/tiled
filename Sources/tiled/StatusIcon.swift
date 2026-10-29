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
/// AppKit-free so the mapping is unit-testable; `MenuBarPresenter` draws
/// the snapshot this produces.
enum StatusIcon {
    /// What the icon currently depicts: layout geometry plus fill. The
    /// presenter diffs this to redraw on occupancy changes, not just
    /// layout switches; windows coming and going within one layout must
    /// flip cells without the layout moving.
    struct Snapshot: Equatable {
        var layout: LayoutKind
        /// Icon cells (members of `cells(for:)`), in icon order, that are
        /// currently covered by a tiled window.
        var filled: [Slot]
        /// Distinct tiled windows on the canvas. `filled.count` counts
        /// lit cells, so a half or a third would overstate the spoken
        /// occupancy; the VoiceOver line needs the window count.
        var occupiedSlots: Int
        /// Display the glyph depicts, when naming it distinguishes the
        /// depiction (more than one display attached). Nil on a single
        /// display, where the display is unambiguous and the spoken line
        /// stays as it was.
        var displayName: String?
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
    /// order. A cell lights when any occupant's cells intersect it:
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
    /// fill, so the delegate diffs a single value. `displayName` travels
    /// with the snapshot so the spoken line names the display the glyph
    /// depicts; it is part of equality, so a focus move to another display
    /// redraws the icon's accessible description even when the occupancy
    /// map is identical.
    static func snapshot(
        layout: LayoutKind, occupants: [Slot: WindowID],
        displayName: String? = nil
    ) -> Snapshot {
        Snapshot(
            layout: layout,
            filled: filledCells(layout: layout, occupants: occupants),
            occupiedSlots: Set(occupants.values).count,
            displayName: displayName)
    }

    /// VoiceOver line for the occupancy map: layout plus how many windows
    /// are tiled. Pure so the count is testable, and window-based so a
    /// half reports "1 of 4 slots occupied", not "2 of 4". When the
    /// snapshot names a display (more than one attached), the line ends
    /// by naming it, matching the menu headers so a VoiceOver user can
    /// tell which display the glyph describes.
    static func accessibilityDescription(_ snapshot: Snapshot) -> String {
        let total = cells(for: snapshot.layout).count
        let line = "Tiled \(snapshot.layout.title) layout, "
            + "\(snapshot.occupiedSlots) of \(total) slots occupied"
        guard let displayName = snapshot.displayName, !displayName.isEmpty else {
            return line
        }
        return line + ", on " + displayName
    }
}
