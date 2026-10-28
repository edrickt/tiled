/// The menu's sticky notice: the latest action receipt, bounded to the
/// focus and action generation it was presented against. A later state
/// change or focus move supersedes it, so returning to the same canvas
/// later cannot resurrect a stale refusal. One value owns present, clear,
/// and overlay, so the guard's fields cannot drift apart.
struct NoticePresentation: Equatable {
    private var receipt: ActionReceipt?
    private var presentedSpace: TilingSpaceKey?
    private var presentedGeneration = 0
    /// Bumped by every controller change. It makes "a later action
    /// supersedes the receipt" exact even when the new notice is nil or
    /// happens to repeat the old text.
    private var generation = 0

    /// A controller change supersedes every earlier receipt.
    mutating func stateDidChange() {
        generation += 1
    }

    /// Focus moved: clear all of it, not just the guard's space, so a
    /// return to the same canvas later cannot resurrect a stale notice.
    mutating func clear() {
        receipt = nil
        presentedSpace = nil
        presentedGeneration = 0
    }

    mutating func present(_ receipt: ActionReceipt, focusedSpace: TilingSpaceKey) {
        self.receipt = receipt
        self.presentedSpace = focusedSpace
        self.presentedGeneration = generation
    }

    /// The menu's notice row. A receipt from another canvas is the latest
    /// user-visible outcome and must not vanish just because the menu reads
    /// the focused canvas; a receipt on this canvas is already carried by
    /// `canvasNotice`. The overlay is bounded to the focus and generation
    /// the receipt was presented against, so a later state change or focus
    /// move supersedes it even when the new notice is nil or repeats the
    /// old text.
    func overlay(
        canvasNotice: String?,
        focusedSpace: TilingSpaceKey
    ) -> String? {
        guard let receipt,
              receipt.canvas != focusedSpace,
              presentedSpace == focusedSpace,
              presentedGeneration == generation
        else { return canvasNotice }
        // Never fall back to the focused canvas's error: that error belongs
        // to another canvas and already has its own menu row, so borrowing
        // it would render the same sentence twice.
        return receipt.notice ?? canvasNotice
    }
}
