import CoreGraphics
import XCTest

@testable import tiled

/// Pins the global-hotkey route: every `HotkeyAction` reaches the one
/// performer call the equivalent menu row uses. The expectations are a
/// local literal switch, not a lookup derived from production, so swapping
/// any two routes fails here.
final class HotkeyActionRouterTests: XCTestCase {
    private final class FakePerformer: HotkeyActionPerformer {
        enum Call: Equatable {
            case tile(SlotKey)
            case expand
            case evict
            case settings
            case undo
            case resetSplitters
            case switchLayout
        }

        private(set) var calls: [Call] = []

        func tile(slotKey: SlotKey) { calls.append(.tile(slotKey)) }
        func performExpandToggle() { calls.append(.expand) }
        func performEvict() { calls.append(.evict) }
        func performSettings() { calls.append(.settings) }
        func performUndo() { calls.append(.undo) }
        func performResetSplitters() { calls.append(.resetSplitters) }
        func performSwitchLayout() { calls.append(.switchLayout) }
    }

    func testEveryActionRoutesToItsIntendedPerformerCall() {
        for action in HotkeyAction.allCases {
            let performer = FakePerformer()

            HotkeyActionRouter(performer: performer).dispatch(action)

            // Independent of the dispatcher: spell out what each action
            // must do, including every slot key's own argument.
            let expected: FakePerformer.Call
            switch action {
            case .slotKey(let key): expected = .tile(key)
            case .expand: expected = .expand
            case .evict: expected = .evict
            case .settings: expected = .settings
            case .undo: expected = .undo
            case .resetSplitters: expected = .resetSplitters
            case .switchLayout: expected = .switchLayout
            }

            XCTAssertEqual(
                performer.calls, [expected],
                "wrong performer call for \(action)")
        }
    }
}

/// The live performer's forwarding bodies: each route reaches the same
/// controller/delegate entry point the menu uses. Built over a fake
/// gateway, so a swapped route fails on observable state.
final class AppHotkeyPerformerTests: XCTestCase {
    private static let screen = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        name: "Display 1")

    private var gateway: FakeWindowGateway!
    private var controller: TilingController!
    private var presentedReceipts: [ActionReceipt] = []
    private var settingsOpened = 0
    private var undoPerformed = 0
    private var performer: AppHotkeyPerformer!

    private var canvas: TilingSpace {
        controller.canvas(for: controller.focusedTilingSpace)
    }

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        controller = TilingController(
            gateway: gateway, pruneInterval: nil, screens: { [Self.screen] })
        presentedReceipts = []
        settingsOpened = 0
        undoPerformed = 0
        performer = AppHotkeyPerformer(
            controller: controller,
            present: { [weak self] in self?.presentedReceipts.append($0) },
            openSettings: { [weak self] in self?.settingsOpened += 1 },
            performUndo: { [weak self] in self?.undoPerformed += 1 })
    }

    @discardableResult
    private func addFocusedWindow() -> WindowHandle {
        let handle = gateway.addWindow(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        gateway.focused = handle
        return handle
    }

    func testTileRoutesToTheControllerAndPresentsItsReceipt() throws {
        addFocusedWindow()

        performer.tile(slotKey: .topLeft)

        XCTAssertEqual(canvas.state.slot(of: 1), .topLeft)
        let receipt = try XCTUnwrap(presentedReceipts.last)
        XCTAssertTrue(receipt.performed)
        XCTAssertNil(receipt.announcement, "a landed placement stays silent")
    }

    func testSwitchLayoutRoutesToTheControllerAndPresentsItsReceipt() throws {
        addFocusedWindow()

        performer.performSwitchLayout()

        XCTAssertEqual(canvas.state.layout, .sixths)
        let receipt = try XCTUnwrap(presentedReceipts.last)
        XCTAssertTrue(receipt.performed)
        XCTAssertEqual(receipt.announcement, "Switched to Sixths.")
    }

    func testExpandRoutesToTheControllerAndPresentsItsReceipt() throws {
        addFocusedWindow()
        controller.handle(slot: .topLeft)

        performer.performExpandToggle()

        XCTAssertTrue(canvas.isExpanded(1))
        let receipt = try XCTUnwrap(presentedReceipts.last)
        XCTAssertTrue(receipt.performed)
        XCTAssertNil(receipt.announcement, "a landed toggle stays silent")
    }

    func testEvictRoutesToTheReceiptPresenter() throws {
        addFocusedWindow()
        controller.handle(slot: .topLeft)

        performer.performEvict()

        let receipt = try XCTUnwrap(presentedReceipts.last)
        XCTAssertTrue(receipt.performed)
        XCTAssertEqual(receipt.announcement, "Focused window evicted.")
        XCTAssertNil(canvas.state.slot(of: 1))
    }

    func testSettingsRoutesToTheDelegate() {
        performer.performSettings()

        XCTAssertEqual(settingsOpened, 1)
    }

    func testUndoRoutesToTheDelegate() {
        performer.performUndo()

        XCTAssertEqual(undoPerformed, 1)
    }

    func testResetSplittersRoutesToTheReceiptPresenterAndBacksUpTheReset() throws {
        let handle = addFocusedWindow()
        controller.handle(slot: .topLeft)
        var echo = gateway.frame(of: handle)!
        echo.size.width -= 10
        gateway.simulateChange(handle, to: echo)
        var dragged = gateway.frame(of: handle)!
        dragged.size.width -= 60
        gateway.simulateChange(handle, to: dragged)
        XCTAssertNotEqual(canvas.grid.columnSplit, 0.5, accuracy: 0.001)
        let draggedGrid = canvas.grid

        performer.performResetSplitters()

        XCTAssertEqual(canvas.grid, GridLayout())
        let receipt = try XCTUnwrap(presentedReceipts.last)
        XCTAssertTrue(receipt.performed)
        XCTAssertEqual(receipt.announcement, "Splitters reset to even splits.")
        XCTAssertTrue(canvas.hasSplitterBackup, "the reset parks its restore")

        // The same hotkey now restores instead of resetting over the
        // parked fractions: one action, two outcomes, never a lost backup.
        performer.performResetSplitters()

        XCTAssertEqual(canvas.grid, draggedGrid)
        XCTAssertFalse(canvas.hasSplitterBackup)
        XCTAssertEqual(
            presentedReceipts.last?.announcement,
            "Splitters restored to their pre-reset positions.")
    }
}
