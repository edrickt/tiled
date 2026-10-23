/// The app-side work behind one global hotkey. `AppHotkeyPerformer`
/// implements it against the live controller; tests stand in a fake and
/// pin every route.
protocol HotkeyActionPerformer: AnyObject {
    func tile(slotKey: SlotKey)
    func performExpandToggle()
    func performEvict()
    func performSettings()
    func performUndo()
    func performResetSplitters()
    func performSwitchLayout()
}

/// The one routing table from a registered `HotkeyAction` to its performer
/// call. The switch is exhaustive, so a new action can never be registered
/// and then silently dropped; a route is a single line a test can pin.
struct HotkeyActionRouter {
    let performer: HotkeyActionPerformer

    func dispatch(_ action: HotkeyAction) {
        switch action {
        case .slotKey(let key): performer.tile(slotKey: key)
        case .expand: performer.performExpandToggle()
        case .evict: performer.performEvict()
        case .settings: performer.performSettings()
        case .undo: performer.performUndo()
        case .resetSplitters: performer.performResetSplitters()
        case .switchLayout: performer.performSwitchLayout()
        }
    }
}

/// The live performer: each route forwards to the same controller or
/// delegate entry point the equivalent menu row uses. Kept out of
/// `AppDelegate` so the forwarding bodies are testable with a fake gateway.
final class AppHotkeyPerformer: HotkeyActionPerformer {
    private let controller: TilingController
    private let present: (ActionReceipt) -> Void
    private let openSettings: () -> Void
    private let performUndoAction: () -> Void

    init(
        controller: TilingController,
        present: @escaping (ActionReceipt) -> Void,
        openSettings: @escaping () -> Void,
        performUndo: @escaping () -> Void
    ) {
        self.controller = controller
        self.present = present
        self.openSettings = openSettings
        self.performUndoAction = performUndo
    }

    func tile(slotKey: SlotKey) {
        present(controller.handle(slotKey: slotKey))
    }

    func performExpandToggle() {
        present(controller.handleExpandToggle())
    }

    func performEvict() {
        present(controller.handleEvict())
    }

    func performSettings() {
        openSettings()
    }

    func performUndo() {
        performUndoAction()
    }

    func performResetSplitters() {
        present(controller.resetOrRestoreSplitters())
    }

    func performSwitchLayout() {
        present(controller.handleSwitchLayout())
    }
}
