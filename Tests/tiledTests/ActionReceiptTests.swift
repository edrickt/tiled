import XCTest
@testable import tiled

/// The four app actions that speak (Evict, Untile All, one window's untile,
/// Undo) return one receipt: whether the action performed, the canvas that
/// owns the outcome, the menu's sticky notice, and exactly one spoken
/// sentence. The delegate presents this receipt, so it can never announce
/// success before the controller's asynchronous no-op/refusal answer lands.
final class ActionReceiptTests: XCTestCase {
    /// Deterministic display: tile geometry comes from this rect, never
    /// the host Mac's screen.
    private static let screen = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        name: "Display 1")

    private var harness: ControllerHarness!
    private var gateway: FakeWindowGateway { harness.gateway }
    private var controller: TilingController { harness.controller }

    /// The canvas the test's single display tiles onto: reads go through
    /// the same accessor actions do.
    private var canvas: TilingSpace { harness.canvas }

    override func setUp() {
        super.setUp()
        harness = ControllerHarness(screens: [Self.screen], deathConfirmation: 0)
        controller.onChange = {}
    }

    private func tiledID(of slot: Slot) -> WindowID {
        guard let id = canvas.state.occupant(of: slot) else {
            XCTFail("expected a tiled window in \(slot.rawValue)")
            return 0
        }
        return id
    }

    /// Builds one ordinary eviction chapter: Safari is evicted from Top
    /// Left when Mail requests that slot. The evictee keeps its record in
    /// the chapter (not on the canvas), ready for Undo to retile it.
    private func buildEvictionChapter() {
        harness.addFocusedWindow(appName: "Safari")
        controller.handle(slot: .topLeft)
        harness.addFocusedWindow(appName: "Notes")
        controller.handle(slot: .topRight)
        harness.addFocusedWindow(appName: "Mail")
        controller.handle(slot: .topLeft)
        XCTAssertEqual(canvas.displacedCount, 1, "the chapter holds one evictee")
    }

    // MARK: Evict

    func testEvictReceiptReportsPerformedWithOneSuccessAnnouncement() {
        harness.addFocusedWindow(appName: "Safari")
        controller.handle(slot: .topLeft)

        let receipt = controller.handleEvict()

        XCTAssertEqual(receipt.canvas, controller.focusedTilingSpace)
        XCTAssertTrue(receipt.performed)
        XCTAssertNil(receipt.notice, "eviction leaves no sticky notice")
        XCTAssertEqual(receipt.announcement, "Focused window evicted.")
    }

    func testEvictWithoutFocusedWindowReceiptAnswersOnce() {
        gateway.focused = nil

        let receipt = controller.handleEvict()

        XCTAssertEqual(receipt.canvas, controller.focusedTilingSpace)
        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(receipt.announcement, "No focused window: click a window first.")
    }

    func testEvictUntiledWindowReceiptAnswersOnce() {
        harness.addFocusedWindow()

        let receipt = controller.handleEvict()

        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(receipt.announcement, "That window isn't tiled: nothing to evict.")
        XCTAssertTrue(canvas.records.isEmpty, "a no-op evict leaves no record")
    }

    func testEvictRefusedRestoreReceiptNamesTheErrorNeverSuccess() {
        let handle = harness.addFocusedWindow(appName: "Safari")
        controller.handle(slot: .topLeft)
        gateway.refuseNextWrites(handle)

        let receipt = controller.handleEvict()

        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(
            receipt.announcement,
            "Couldn't restore “Safari”: it may still be sitting in its old tile.")
        XCTAssertEqual(receipt.notice, receipt.announcement, "the menu carries the refusal")
        XCTAssertFalse(receipt.announcement!.contains("evicted"))
    }

    // MARK: Untile All

    func testUntileAllReceiptReportsPerformedWithStickyNotice() {
        harness.addFocusedWindow(appName: "Safari")
        controller.handle(slot: .topLeft)
        harness.addFocusedWindow(appName: "Notes")
        controller.handle(slot: .topRight)

        let receipt = controller.untileAll()

        XCTAssertEqual(receipt.canvas, controller.focusedTilingSpace)
        XCTAssertTrue(receipt.performed)
        XCTAssertEqual(
            receipt.notice,
            "Untiled 2 windows. Press \u{2303}\u{2325}\u{21E7}\u{2318}Z to undo.")
        XCTAssertEqual(receipt.notice, canvas.notice)
        XCTAssertEqual(receipt.announcement, "All tiled windows restored.")
    }

    func testUntileAllOnEmptyCanvasReceiptAnswersOnce() {
        let receipt = controller.untileAll()

        XCTAssertFalse(receipt.performed)
        XCTAssertNil(receipt.notice)
        XCTAssertEqual(receipt.announcement, "No tiled windows on this canvas.")
    }

    func testUntileAllRefusedRestoreReceiptNamesTheErrorNeverSuccess() {
        let handle = harness.addFocusedWindow(appName: "Safari")
        controller.handle(slot: .topLeft)
        gateway.refuseNextWrites(handle)

        let receipt = controller.untileAll()

        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(
            receipt.announcement,
            "Couldn't restore “Safari”: it may still be sitting in its old tile.")
        XCTAssertEqual(receipt.notice, receipt.announcement, "the menu carries the refusal")
        XCTAssertEqual(canvas.error, receipt.announcement, "the canvas carries the refusal too")
        XCTAssertFalse(receipt.announcement!.contains("restored"))
    }

    // MARK: Single-window untile

    func testUntileWindowReceiptReportsPerformedWithWindowName() {
        harness.addFocusedWindow(appName: "Safari")
        controller.handle(slot: .topLeft)
        let id = tiledID(of: .topLeft)

        let receipt = controller.untile(window: id)

        XCTAssertEqual(receipt.canvas, controller.focusedTilingSpace)
        XCTAssertTrue(receipt.performed)
        XCTAssertNil(receipt.notice)
        XCTAssertEqual(receipt.announcement, "Safari untiled.")
    }

    func testUntileWindowWithoutAppNameUsesWindowFallback() {
        harness.addFocusedWindow(appName: nil)
        controller.handle(slot: .topLeft)
        let id = tiledID(of: .topLeft)

        let receipt = controller.untile(window: id)

        XCTAssertTrue(receipt.performed)
        XCTAssertEqual(receipt.announcement, "Window untiled.")
    }

    func testUntileWindowOfUntiledWindowReceiptAnswersOnce() {
        harness.addFocusedWindow(appName: "Safari")

        let receipt = controller.untile(window: 1)

        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(
            receipt.announcement, "That window isn't tiled: nothing to untile.")
    }

    func testUntileWindowOfUntiledWindowLeavesTheStickyNoticeAlone() {
        harness.addFocusedWindow(appName: "Safari")
        controller.handle(slot: .topLeft)
        let id = tiledID(of: .topLeft)
        controller.untileAll()
        let notice = canvas.notice
        XCTAssertNotNil(notice)

        let receipt = controller.untile(window: id)

        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(
            canvas.notice, notice,
            "a true no-op must not clear the live undo receipt")
    }

    func testUntileWindowRefusedRestoreReceiptNamesTheErrorNeverSuccess() {
        let handle = harness.addFocusedWindow(appName: "Safari")
        controller.handle(slot: .topLeft)
        let id = tiledID(of: .topLeft)
        gateway.refuseNextWrites(handle)

        let receipt = controller.untile(window: id)

        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(
            receipt.announcement,
            "Couldn't restore “Safari”: it may still be sitting in its old tile.")
        XCTAssertEqual(receipt.notice, receipt.announcement)
        XCTAssertFalse(receipt.announcement!.contains("untiled"))
    }

    func testBackgroundCanvasUntileRefusalNamesItsDisplayAndWindow() {
        let left = ScreenInfo(
            id: ScreenID(rawValue: 1),
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            name: "Display 1")
        let right = ScreenInfo(
            id: ScreenID(rawValue: 2),
            frame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
            name: "Display 2")
        harness = ControllerHarness(
            screens: [left, right], deathConfirmation: 0)
        controller.onChange = {}

        // Tile Safari on the second display, then move focus to an untiled
        // window on the first: the untile row now acts on a background canvas.
        let safari = gateway.addWindow(
            frame: CGRect(x: 2000, y: 100, width: 800, height: 600), appName: "Safari")
        gateway.focused = safari
        controller.handle(slot: .topLeft)
        let rightCanvas = controller.canvas(for: right.id)
        let id = rightCanvas.state.occupant(of: .topLeft)!
        gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        gateway.focused = gateway.issued[1]
        XCTAssertEqual(controller.focusedTilingSpace.screen, left.id)
        gateway.refuseNextWrites(safari)

        let receipt = controller.untile(window: id)

        XCTAssertEqual(
            receipt.canvas, TilingSpaceKey(screen: right.id, space: nil),
            "the receipt names the canvas whose window was untiled")
        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(
            receipt.announcement,
            "Display 2: Couldn't restore “Safari”: it may still be sitting in its old tile.")
        XCTAssertFalse(receipt.announcement!.contains("untiled"))
    }

    // MARK: Undo

    func testUndoReceiptReportsPerformedWithOneSuccessAnnouncement() {
        buildEvictionChapter()

        let receipt = controller.undoAction()

        XCTAssertEqual(receipt.canvas, controller.focusedTilingSpace)
        XCTAssertTrue(receipt.performed)
        XCTAssertEqual(receipt.notice, "Undid displacement \u{00B7} 1 window restored.")
        XCTAssertEqual(receipt.notice, canvas.notice)
        XCTAssertEqual(receipt.announcement, "Displaced windows restored.")
    }

    func testUndoEmptyStackReceiptAnswersOnceNeverSuccess() {
        harness.addFocusedWindow(appName: "Safari")
        XCTAssertTrue(canvas.undoStack.isEmpty)

        let receipt = controller.undoAction()

        XCTAssertEqual(receipt.canvas, controller.focusedTilingSpace)
        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(
            receipt.announcement, "Nothing to undo: a later change replaced it.")
        XCTAssertNotEqual(receipt.announcement, "Displaced windows restored.")
    }

    func testUndoRefusedRestoreReceiptNamesTheErrorNeverSuccess() {
        buildEvictionChapter()
        gateway.refuseNextWrites(gateway.issued[0]) // Safari, the evictee

        let receipt = controller.undoAction()

        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(
            receipt.announcement,
            "Couldn't restore “Safari”: it may still be sitting in its old tile.")
        XCTAssertEqual(receipt.notice, receipt.announcement)
        XCTAssertFalse(receipt.announcement!.contains("restored"))
    }

    func testUndoChapterWhoseWindowsAllDiedReceiptReportsTheFailure() {
        buildEvictionChapter()
        gateway.kill(gateway.issued[0])

        let receipt = controller.undoAction()

        XCTAssertFalse(receipt.performed)
        XCTAssertEqual(receipt.announcement, "Couldn't restore the displaced windows.")
        XCTAssertEqual(receipt.notice, receipt.announcement)
    }

    // MARK: Bool seam

    func testUndoBoolSeamReturnsFalseOnEmptyStackWithoutFeedback() {
        harness.addFocusedWindow()

        let performed = controller.undoLastDisplacement()

        XCTAssertFalse(performed)
    }
}
