import XCTest

@testable import tiled

/// The README's one-step restore contract at the drag boundary: a drag
/// alone never arms a restore, a drag after Reset leaves the parked
/// backup alone, and a second Reset replaces it. Driven through the real
/// controller and DragTracker over the fake gateway.
final class SplitterBackupDragTests: XCTestCase {
    private static let screen = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        name: "Display 1")

    private var gateway: FakeWindowGateway!
    private var controller: TilingController!
    private var handle: WindowHandle!

    private var canvas: TilingSpace {
        controller.canvas(for: controller.focusedTilingSpace)
    }

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        controller = TilingController(
            gateway: gateway,
            pruneInterval: nil,
            scheduleDragEnd: { _ in {} },
            scheduleVerify: { _ in {} },
            screens: { [Self.screen] })
        handle = gateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        gateway.focused = handle
        controller.handle(slot: .topLeft)
    }

    /// Drags Top Left's right edge right by `delta`, then releases.
    private func dragRightEdge(by delta: CGFloat) {
        var echo = gateway.frame(of: handle)!
        echo.size.width -= 10
        gateway.simulateChange(handle, to: echo)
        var dragged = gateway.frame(of: handle)!
        dragged.size.width += delta
        gateway.simulateChange(handle, to: dragged)
        controller.mouseLifted()
    }

    func testDragWithoutResetNeverArmsARestore() {
        dragRightEdge(by: 60)

        XCTAssertNotEqual(
            canvas.grid.columnSplit, 0.5, accuracy: 0.001,
            "the drag moved the splitter")
        XCTAssertFalse(
            canvas.hasSplitterBackup,
            "an ordinary drag is not a reset and must not arm Restore")
    }

    func testDragAfterResetLeavesTheParkedBackupAlone() {
        controller.resetOrRestoreSplitters()
        let parked = canvas.splitterBackup
        XCTAssertNotNil(parked)

        dragRightEdge(by: 60)

        XCTAssertTrue(canvas.hasSplitterBackup, "the drag does not consume the receipt")
        XCTAssertEqual(canvas.splitterBackup, parked, "the parked fractions survive the drag")
        XCTAssertTrue(controller.resetOrRestoreSplitters().performed)
        XCTAssertEqual(
            canvas.grid, parked,
            "Restore returns the positions parked before the reset, not the dragged ones")
        XCTAssertFalse(canvas.hasSplitterBackup, "restoring consumes the backup")
    }

    func testSecondPressRestoresInsteadOfOverwritingTheParkedSnapshot() {
        // The shipped action is one control, not two: while a backup
        // exists the same press restores it. A reset route that could run
        // again would overwrite the only way back, so it does not exist.
        controller.resetOrRestoreSplitters()
        let parked = canvas.splitterBackup
        dragRightEdge(by: 60)
        let dragged = canvas.grid
        XCTAssertNotEqual(dragged.columnSplit, parked?.columnSplit ?? 0, accuracy: 0.001)

        let receipt = controller.resetOrRestoreSplitters()

        XCTAssertTrue(receipt.performed, "the second press restored")
        XCTAssertEqual(
            canvas.grid, parked,
            "the second press lands the first snapshot instead of overwriting it")
        XCTAssertFalse(canvas.hasSplitterBackup, "restoring consumes the backup")
    }
}
