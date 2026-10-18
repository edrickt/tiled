/// What the focused window's ⌥⇧⏎ toggle does right now: the expand menu
/// row's state. A stateless toggle would leave the user guessing what
/// "expand" means when the window already covers its screen.
///
/// Platform-free so the row's wording can be pinned without building
/// AppKit menus or reading live windows.
enum ExpandToggleState: Equatable {
    /// The focused window is not expanded: the toggle fills the screen.
    case expands
    /// The focused window is expanded and still holds a slot: the toggle
    /// retiles it into that slot.
    case returnsToSlot(Slot)
    /// The focused window is expanded and untiled: the toggle restores
    /// the frame it had before expanding. An untiled expansion has no
    /// slot to name, but it still has a state the row must show.
    case returnsToPreviousFrame
}
