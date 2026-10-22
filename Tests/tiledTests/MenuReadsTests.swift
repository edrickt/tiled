import XCTest
@testable import tiled

/// One `MenuReads` pass from one canvas key: the canvas's own error and
/// notice, the hotkey warnings, the aggregate rows, focus, trust, and the
/// layout map all come from that key. A background canvas's menu can never
/// borrow the focused canvas's refusal.
final class MenuReadsTests: XCTestCase {
    private static let left = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        name: "Built-in")
    private static let right = ScreenInfo(
        id: ScreenID(rawValue: 2),
        frame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
        name: "Studio Display")

    private var gateway: FakeWindowGateway!
    private var controller: TilingController!

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            screens: { [Self.left, Self.right] }, deathConfirmation: 0)
        controller.onChange = {}
    }

    private func reads(
        for space: TilingSpaceKey,
        failedActions: [HotkeyAction] = []
    ) -> MenuReads {
        MenuReads(
            space: space, controller: controller,
            failedActions: failedActions,
            binding: { $0.defaultBinding })
    }

    /// Tiles Safari on the right display, then refuses Mail's placement
    /// there; on the left, refuses Notes's placement. Both canvases now
    /// carry distinct errors, and focus sits on the left one.
    private func makeTwoCanvasRefusals() -> (safari: WindowHandle, notes: WindowHandle) {
        let safari = gateway.addWindow(
            frame: CGRect(x: 2000, y: 100, width: 800, height: 600), appName: "Safari")
        gateway.focused = safari
        controller.handle(slot: .topLeft)

        let mail = gateway.addWindow(
            frame: CGRect(x: 2000, y: 700, width: 800, height: 300), appName: "Mail")
        gateway.focused = mail
        gateway.refuseNextWrites(mail)
        controller.handle(slot: .bottomLeft)

        let notes = gateway.addWindow(
            frame: CGRect(x: 100, y: 100, width: 800, height: 600), appName: "Notes")
        gateway.focused = notes
        gateway.refuseNextWrites(notes)
        controller.handle(slot: .topLeft)
        return (safari, notes)
    }

    func testReadsScopeTheErrorAndRowsToThePassedCanvasNotFocus() {
        let (safari, notes) = makeTwoCanvasRefusals()
        gateway.focused = notes
        XCTAssertEqual(controller.focusedTilingSpace.screen, Self.left.id)

        let rightKey = TilingSpaceKey(screen: Self.right.id, space: nil)
        let pass = reads(for: rightKey)

        XCTAssertEqual(
            pass.tileError,
            "Mail couldn't be tiled: the app refused to resize it.",
            "the pass describes its canvas, not the focused canvas's Notes refusal")
        XCTAssertEqual(pass.canvas.state.activeLayout, .quarters)
        XCTAssertEqual(pass.hasFocusedWindow, true)
        XCTAssertEqual(
            pass.rows.map(\.id), [safari.id],
            "the aggregate rows still see Safari on the background display")

        let left = reads(for: TilingSpaceKey(screen: Self.left.id, space: nil))
        XCTAssertEqual(
            left.tileError,
            "Notes couldn't be tiled: the app refused to resize it.")
    }

    func testSnapshotDerivesOnlyFromTheReads() {
        _ = makeTwoCanvasRefusals()
        let rightKey = TilingSpaceKey(screen: Self.right.id, space: nil)
        let pass = reads(for: rightKey, failedActions: [.expand])

        let snapshot = MenuModel.Snapshot(reads: pass, notice: "Overlay notice")

        XCTAssertEqual(snapshot.isTrusted, true)
        XCTAssertEqual(
            snapshot.tileError,
            "Mail couldn't be tiled: the app refused to resize it.")
        XCTAssertEqual(
            snapshot.warnings,
            ["The Expand to Fill Screen shortcut (⌥⇧⏎) could not be registered; "
                + "quit and reopen Tiled to try again."])
        XCTAssertEqual(snapshot.notice, "Overlay notice")
        XCTAssertEqual(snapshot.activeLayout, .quarters)
        XCTAssertEqual(snapshot.untileCount, 1)
        XCTAssertEqual(snapshot.layoutTitle, "Studio Display · Quarters · 1 tiled")
        XCTAssertEqual(snapshot.monitorSections, [
            .init(title: "Studio Display · Quarters · 1 tiled", key: Self.right.id),
        ])
    }

    func testHasFocusedWindowIsOneControllerRead() {
        XCTAssertFalse(reads(for: controller.focusedTilingSpace).hasFocusedWindow)

        let safari = gateway.addWindow(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600), appName: "Safari")
        gateway.focused = safari

        XCTAssertTrue(reads(for: controller.focusedTilingSpace).hasFocusedWindow)

        gateway.focused = nil
        XCTAssertFalse(reads(for: controller.focusedTilingSpace).hasFocusedWindow)
    }
}
