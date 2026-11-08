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
        XCTAssertEqual(pass.canvas.state.layout, .quarters)
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

    func testReadsCarryTheCanvasLayoutWithNoFocusedWindow() {
        // The switch row no longer needs focus, so the reads carry the
        // canvas layout rather than a focus flag.
        XCTAssertEqual(reads(for: controller.focusedTilingSpace).canvas.state.layout, .quarters)

        let safari = gateway.addWindow(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600), appName: "Safari")
        gateway.focused = safari
        controller.handleSwitchLayout(to: .quarters)

        XCTAssertEqual(reads(for: controller.focusedTilingSpace).canvas.state.layout, .quarters)

        gateway.focused = nil
        XCTAssertEqual(
            reads(for: controller.focusedTilingSpace).canvas.state.layout, .quarters,
            "an empty switched canvas keeps its layout with nothing focused")
    }

    func testOneDisplayWithTwoLayoutsOmitsTheLayoutFromItsHeader() {
        // A display can show an identified canvas and still keep a
        // withheld fallback holding windows. When the two canvases run
        // different layouts, one section per display cannot name a single
        // layout: the header (and the status line built from it) omits it
        // rather than asserting one canvas's layout for the other's row.
        let displayID: CGDirectDisplayID = 42
        let display = ScreenInfo(
            id: ScreenID(rawValue: 1),
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            name: "Built-in",
            displayID: displayID)
        let gateway = FakeWindowGateway()
        let controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            screens: { [display] }, deathConfirmation: 0)
        controller.onChange = {}

        // While the display's Space is withheld, Safari tiles on the
        // per-display fallback canvas, which stays in quarters.
        let safari = gateway.addWindow(
            frame: CGRect(x: 100, y: 100, width: 800, height: 600), appName: "Safari")
        gateway.focused = safari
        controller.handle(slot: .topLeft)

        // The display names its Space: Notes tiles on the identified
        // canvas, which switches to sixths and re-tiles Notes there.
        gateway.activeSpaces = [displayID: SpaceID(rawValue: 7)]
        let notes = gateway.addWindow(
            frame: CGRect(x: 900, y: 100, width: 800, height: 600), appName: "Notes")
        gateway.focused = notes
        controller.handle(slot: .topRight)
        controller.handleSwitchLayout(to: .sixths)
        controller.handle(slotKey: .topLeft)

        let identified = TilingSpaceKey(screen: display.id, space: SpaceID(rawValue: 7))
        let withheld = TilingSpaceKey(screen: display.id, space: nil)
        XCTAssertEqual(controller.canvas(for: identified).state.layout, .sixths)
        XCTAssertEqual(controller.canvas(for: withheld).state.layout, .quarters)
        XCTAssertEqual(controller.canvas(for: identified).state.tiledWindows.count, 1)
        XCTAssertEqual(controller.canvas(for: withheld).state.tiledWindows.count, 1)

        let reads = MenuReads(
            space: controller.focusedTilingSpace, controller: controller,
            failedActions: [], binding: { $0.defaultBinding })
        XCTAssertEqual(
            Set(reads.rows.compactMap(\.appName)), ["Safari", "Notes"],
            "both canvases' windows list under the one display")
        XCTAssertEqual(
            reads.layout(for: display.id), .sixths,
            "a display-scoped action resolves the identified canvas")
        let snapshot = MenuModel.Snapshot(reads: reads, notice: nil)
        XCTAssertEqual(snapshot.layoutTitle, "Built-in · 2 tiled")
        XCTAssertEqual(snapshot.monitorSections, [
            .init(title: "Built-in · 2 tiled", key: display.id),
        ])
    }

    func testABackgroundBirthRefusalReachesTheMenuWithItsDisplayName() {
        // A birth on a display the user is not focused on is refused by
        // its app. The birth returns no receipt and the focused canvas's
        // error is empty, so the aggregated background row is the only
        // place the refusal can surface.
        let left = ScreenInfo(
            id: ScreenID(rawValue: 1),
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            name: "Built-in",
            displayID: 42)
        let right = ScreenInfo(
            id: ScreenID(rawValue: 2),
            frame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
            name: "Studio Display",
            displayID: 43)
        let gateway = FakeWindowGateway()
        let controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            screens: { [left, right] }, deathConfirmation: 0)
        controller.onChange = {}

        let focused = gateway.addWindow(
            frame: CGRect(x: 100, y: 100, width: 800, height: 600), appName: "Notes")
        gateway.focused = focused

        // Every write is refused: the new window's birth sizing on the
        // other display cannot land.
        gateway.willWrite = { handle in gateway.refuseNextWrites(handle) }
        gateway.simulateWindowCreated(
            frame: CGRect(x: 2000, y: 100, width: 800, height: 600))
        gateway.willWrite = nil

        let birthCanvas = TilingSpaceKey(screen: right.id, space: nil)
        XCTAssertEqual(
            controller.canvas(for: birthCanvas).error,
            "Couldn't move that window: the app refused to resize it.")
        XCTAssertEqual(controller.focusedTilingSpace.screen, left.id)

        let reads = MenuReads(
            space: controller.focusedTilingSpace, controller: controller,
            failedActions: [], binding: { $0.defaultBinding })
        XCTAssertNil(reads.tileError, "the focused canvas refused nothing")
        XCTAssertEqual(reads.backgroundTileErrors, [
            "Studio Display: Couldn't move that window: the app refused to resize it."
        ])

        let snapshot = MenuModel.Snapshot(reads: reads, notice: nil)
        XCTAssertEqual(snapshot.backgroundTileErrors, reads.backgroundTileErrors)
        let model = MenuModel.items(snapshot: snapshot)
        XCTAssertTrue(
            model.contains {
                $0.title
                    == "Studio Display: Couldn't move that window: the app refused to resize it."
                    && !$0.isEnabled
            },
            "the background refusal renders as its own disabled row")
    }
}
