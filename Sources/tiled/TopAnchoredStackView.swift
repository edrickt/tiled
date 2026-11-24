import AppKit

/// Vertical stack for use as an NSScrollView documentView: flipped, so
/// the clip view inherits flippedness and content shorter than the
/// viewport hugs the top. A plain (non-flipped) stack gets stretched to
/// the visible height and its rows sink to the bottom of the tab.
///
/// Pair with leading/trailing/top pins to the scroll view's content view
/// and **no bottom constraint**. A bottom pin (even `>=`) stretches the
/// stack to the viewport, and NSStackView's gravityAreas then pins the
/// last arranged views to the bottom edge, which is exactly the sinking
/// this type exists to prevent; the flipped geometry keeps short content
/// at the top instead.
final class TopAnchoredStackView: NSStackView {
    override var isFlipped: Bool { true }
}
