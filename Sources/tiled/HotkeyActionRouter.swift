/// The app-side work behind one global hotkey. `AppHotkeyPerformer`
/// implements it against the live controller; tests stand in a fake and
/// pin every route.
protocol HotkeyActionPerformer: AnyObject {
    func tile(slot: Slot)
    func performExpandToggle()
    func performEvict()
    func performSettings()
    func performUndo()
    func performResetSplitters()
}

/// The one routing table from a registered `HotkeyAction` to its performer
/// call. The switch is exhaustive, so a new action can never be registered
/// and then silently dropped; a route is a single line a test can pin.
struct HotkeyActionRouter {
    let performer: HotkeyActionPerformer

    func dispatch(_ action: HotkeyAction) {
        switch action {
        case .slot(let slot): performer.tile(slot: slot)
        case .expand: performer.performExpandToggle()
        case .evict: performer.performEvict()
        case .settings: performer.performSettings()
        case .undo: performer.performUndo()
        case .resetSplitters: performer.performResetSplitters()
        }
    }
}

/// The live performer: each route forwards to the same controller or
/// delegate entry point the equivalent menu row uses. Kept out of
/// `AppDelegate` so the forwarding bodies are testable with a fake gateway.
final class AppHotkeyPerformer: HotkeyActionPerformer {
    private let controller: TilingController
    private let presentEvict: (ActionReceipt) -> Void
    private let openSettings: () -> Void
    private let performUndoAction: () -> Void

    init(
        controller: TilingController,
        presentEvict: @escaping (ActionReceipt) -> Void,
        openSettings: @escaping () -> Void,
        performUndo: @escaping () -> Void
    ) {
        self.controller = controller
        self.presentEvict = presentEvict
        self.openSettings = openSettings
        self.performUndoAction = performUndo
    }

    func tile(slot: Slot) {
        controller.handle(slot: slot)
    }

    func performExpandToggle() {
        controller.handleExpandToggle()
    }

    func performEvict() {
        presentEvict(controller.handleEvict())
    }

    func performSettings() {
        openSettings()
    }

    func performUndo() {
        performUndoAction()
    }

    func performResetSplitters() {
        controller.resetDividers()
    }
}
