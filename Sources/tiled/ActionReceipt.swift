/// One app action's user-visible truth: whether it performed, which canvas
/// owns the outcome, the menu's sticky notice, and exactly one spoken
/// sentence (nil = silent). The controller builds it after the action, when
/// the canvas's notice/error and the restore verdict are settled; the
/// delegate only presents it. This is what stops an announcement from
/// outrunning the action and speaking success over an asynchronous no-op or
/// refusal.
struct ActionReceipt: Equatable {
    /// The canvas whose state the action changed (or would have changed):
    /// menus read the focused canvas, but a background window's untile row
    /// still reports the canvas that owns that window.
    let canvas: TilingSpaceKey
    /// True only when something actually changed and no restore refused.
    let performed: Bool
    /// The canvas's sticky notice/error after the action: the text the menu
    /// carries until the next action replaces it.
    let notice: String?
    /// The one sentence to speak; nil means the action stays silent.
    let announcement: String?
}
