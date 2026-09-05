import AppKit

/// Vertical stack for use as an NSScrollView documentView: flipped, so
/// the clip view inherits flippedness and content shorter than the
/// viewport hugs the top. A plain (non-flipped) stack gets stretched to
/// the visible height and its rows sink to the bottom of the tab.
/// Pair with: top == contentView.top, bottom >= contentView.bottom.
final class TopAnchoredStackView: NSStackView {
    override var isFlipped: Bool { true }
}
