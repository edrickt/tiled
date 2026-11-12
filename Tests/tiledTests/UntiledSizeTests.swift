import CoreGraphics
import XCTest
@testable import tiled

/// The pure sizing every untile exit shares: the quarters regular
/// even-split footprint, hung from the window's top edge, kept inside
/// the visible frame.
final class UntiledSizeTests: XCTestCase {
    func testSizedUntileFrameKeepsTopEdgeAndMatchesTileSize() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let source = CGRect(x: 100, y: 100, width: 700, height: 900)
        XCTAssertEqual(
            GridLayout().sizedUntileFrame(keepingTopOf: source, in: bounds),
            CGRect(x: 100, y: 500, width: 800, height: 500))
    }

    func testSizedUntileFrameRepinsInsideBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        XCTAssertEqual(
            GridLayout().sizedUntileFrame(
                keepingTopOf: CGRect(x: 1500, y: 900, width: 200, height: 200),
                in: bounds),
            CGRect(x: 800, y: 500, width: 800, height: 500))
    }

    func testSizedUntileFrameIgnoresDragEditedSplits() {
        // A canvas whose splitters were drag-edited still untile-births
        // the regular even-split footprint, never the edited one.
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        var edited = GridLayout()
        edited.columnSplit = 0.1
        edited.sixthsLeftSplit = 0.1
        XCTAssertEqual(
            edited.sizedUntileFrame(
                keepingTopOf: CGRect(x: 12, y: 34, width: 700, height: 900),
                in: bounds),
            CGRect(x: 12, y: 434, width: 800, height: 500))
    }

    func testSizedUntileFrameDegenerateBoundsSkips() {
        let frame = GridLayout().sizedUntileFrame(
            keepingTopOf: CGRect(x: 12, y: 34, width: 0, height: 0),
            in: .zero)
        XCTAssertEqual(frame.origin, CGPoint(x: 12, y: 34))
        XCTAssertEqual(frame.size, .zero)
        XCTAssertTrue(
            [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite))
    }

    func testQuarterOnlyHelperAlwaysUsesTopLeft() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        XCTAssertEqual(
            GridLayout().sizedUntileFrame(
                keepingTopOf: CGRect(x: 10, y: 10, width: 800, height: 600),
                in: bounds),
            CGRect(x: 10, y: 110, width: 800, height: 500))
    }
}

/// A newly created window is adopted as an untiled managed window at the
/// frame its app opened it at: Tiled never resizes a birth, never writes
/// it, and never auto-tiles it. Only readable geometry claims a record.
final class WindowBirthTests: XCTestCase {
    private static let screen = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        name: "Display 1",
        displayID: CGDirectDisplayID(42))

    private static let spaceA = SpaceID(rawValue: 101)

    private var harness: ControllerHarness!
    private var gateway: FakeWindowGateway { harness.gateway }
    private var controller: TilingController { harness.controller }
    private var canvas: TilingSpace { harness.canvas }

    override func setUp() {
        super.setUp()
        harness = ControllerHarness(
            screens: [Self.screen],
            activeSpaces: [Self.screen.displayID: Self.spaceA],
            deathConfirmation: 0)
        harness.fireCursorMove(to: CGPoint(x: 500, y: 500))
    }

    func testNewWindowIsAdoptedAtTheFrameItsAppChose() {
        // Whatever layout the canvas shows, a birth keeps the app's frame:
        // Tiled never resizes a new window to a quarter.
        controller.handleSwitchLayout(to: .sixths)
        let birth = CGRect(x: 10, y: 10, width: 800, height: 600)

        let handle = gateway.simulateWindowCreated(frame: birth)

        XCTAssertEqual(
            gateway.frame(of: handle), birth, "a birth is never resized")
        XCTAssertTrue(gateway.writes.isEmpty, "a birth draws no write")
        let id = controller.registeredID(for: handle)
        XCTAssertNotNil(id, "a birth is still an untiled managed window")
        XCTAssertNil(
            canvas.state.slot(of: id!), "a birth is never auto-tiled")
        XCTAssertEqual(
            canvas.record(of: id!)?.preTileFrame, birth,
            "the record keeps the frame the app opened")
    }

    func testZeroFrameBirthClaimsNothing() {
        let handle = gateway.simulateWindowCreated(frame: .zero)

        XCTAssertTrue(
            gateway.writes.isEmpty,
            "a window with no readable geometry draws no write")
        XCTAssertNil(
            controller.registeredID(for: handle),
            "a window with no readable geometry claims no record")
    }

    func testUnreadableBirthClaimsNothing() {
        let handle = gateway.addWindow(
            frame: CGRect(x: 10, y: 10, width: 800, height: 600))
        gateway.hideFrames.insert(handle)
        gateway.clearWrites()

        controller.handleWindowCreated(handle)

        XCTAssertTrue(
            gateway.writes.isEmpty, "an unreadable birth draws no write")
        XCTAssertNil(
            controller.registeredID(for: handle),
            "an unreadable birth claims no record")
    }

    func testBirthThenCloseClaimsNothing() {
        let handle = gateway.addWindow(
            frame: CGRect(x: 10, y: 10, width: 800, height: 600))
        gateway.kill(handle)
        gateway.clearWrites()

        controller.handleWindowCreated(handle)

        XCTAssertTrue(
            gateway.writes.isEmpty,
            "a window dead on arrival draws no write")
        XCTAssertNil(controller.registeredID(for: handle))
    }

    func testDuplicateDeliveryKeepsTheFirstRecord() {
        let birth = CGRect(x: 10, y: 10, width: 800, height: 600)
        let handle = gateway.simulateWindowCreated(frame: birth)
        let id = controller.registeredID(for: handle)

        controller.handleWindowCreated(handle, at: birth)

        XCTAssertEqual(
            controller.registeredID(for: handle), id,
            "a duplicate delivery keeps the first birth's record")
        XCTAssertEqual(
            canvas.record(of: id!)?.preTileFrame, birth,
            "the duplicate never rewrites the recorded frame")
        XCTAssertTrue(gateway.writes.isEmpty)
    }

    func testBirthSubscriptionResubscribesOnTrustGrant() {
        XCTAssertEqual(
            gateway.creationSubscriptions, 1,
            "init subscribes the creation hook once")

        controller.observeWindowCreations()

        XCTAssertEqual(
            gateway.creationSubscriptions, 2,
            "a trust grant re-subscribes already-running apps")
        let birth = CGRect(x: 10, y: 10, width: 800, height: 600)
        let handle = gateway.simulateWindowCreated(frame: birth)
        XCTAssertEqual(
            gateway.frame(of: handle), birth,
            "the latest subscription still adopts births where the app put them")
        XCTAssertNotNil(controller.registeredID(for: handle))
    }

    func testRetilingABirthUsesItsOwnFrameAsThePreTileFrame() {
        let birth = CGRect(x: 10, y: 10, width: 800, height: 600)
        let handle = gateway.simulateWindowCreated(frame: birth)
        gateway.focused = handle
        controller.handle(slot: .topLeft)
        let id = controller.registeredID(for: handle)!

        XCTAssertEqual(canvas.state.slot(of: id), .topLeft)
        XCTAssertEqual(
            canvas.record(of: id)?.preTileFrame, birth,
            "the tile reads the app's frame as its pre-tile frame")
        XCTAssertNil(
            canvas.deferredRestores[handle],
            "tiling a birth leaves no stale restore behind")
        XCTAssertTrue(controller.untile(window: id).performed)
        XCTAssertEqual(
            gateway.frame(of: handle),
            CGRect(x: 10, y: 110, width: 800, height: 500),
            "the untile exit still sizes the quarter footprint from that frame")
    }

    func testBirthMidDragIsAdoptedWhereTheAppPutIt() {
        // Tearing a tab off Firefox delivers the birth while the button
        // is down: there is no resize to park, so the window is simply
        // adopted where the app put it.
        controller.isMouseDown = { true }
        let birth = CGRect(x: 10, y: 10, width: 800, height: 600)

        let handle = gateway.simulateWindowCreated(frame: birth)

        XCTAssertEqual(
            gateway.frame(of: handle), birth,
            "a mid-drag birth leaves the window where the app put it")
        XCTAssertTrue(
            gateway.writes.isEmpty, "a mid-drag birth draws no write")
        XCTAssertNotNil(controller.registeredID(for: handle))

        controller.isMouseDown = { false }
        controller.mouseLifted()
        XCTAssertEqual(
            gateway.frame(of: handle), birth,
            "mouse-up has no parked size to land")
        XCTAssertTrue(gateway.writes.isEmpty)
    }

    func testBirthTiledMidDragKeepsTile() {
        controller.isMouseDown = { true }
        let handle = gateway.simulateWindowCreated(
            frame: CGRect(x: 10, y: 10, width: 800, height: 600))
        gateway.focused = handle
        controller.handle(slot: .topLeft)
        let id = controller.registeredID(for: handle)!
        let tiled = gateway.frame(of: handle)!
        XCTAssertEqual(canvas.state.slot(of: id), .topLeft)
        gateway.clearWrites()
        controller.isMouseDown = { false }

        controller.mouseLifted()

        XCTAssertEqual(
            gateway.frame(of: handle), tiled,
            "a birth tiled mid-drag keeps its tile on mouse-up")
        XCTAssertTrue(gateway.writes.isEmpty)
    }

    func testBirthRecordsOnTheWindowsOwnDisplay() {
        // Cursor on display 1, window opens on display 2: the record
        // lives on display 2's canvas, never the cursor's.
        let second = ScreenInfo(
            id: ScreenID(rawValue: 2),
            frame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
            name: "Display 2",
            displayID: CGDirectDisplayID(43))
        let secondSpace = SpaceID(rawValue: 102)
        harness = ControllerHarness(
            screens: [Self.screen, second],
            activeSpaces: [
                Self.screen.displayID: Self.spaceA,
                second.displayID: secondSpace,
            ],
            deathConfirmation: 0)
        harness.fireCursorMove(to: CGPoint(x: 500, y: 500))
        gateway.clearWrites()
        let birth = CGRect(x: 1700, y: 100, width: 800, height: 600)

        let handle = gateway.simulateWindowCreated(frame: birth)

        XCTAssertEqual(
            gateway.frame(of: handle), birth, "a birth keeps its frame")
        let id = controller.registeredID(for: handle)!
        XCTAssertNotNil(
            controller.canvas(
                for: TilingSpaceKey(screen: second.id, space: secondSpace)
            ).record(of: id),
            "the birth record lives on the window's canvas")
        XCTAssertNil(
            controller.canvas(
                for: TilingSpaceKey(screen: Self.screen.id, space: Self.spaceA)
            ).record(of: id),
            "the cursor's canvas claims nothing")
    }

    func testAnOffDisplayBirthRecordsOnTheCursorDisplay() {
        // Cursor on display 2, frame owned by no display: the record
        // falls to the cursor's canvas, never the main display by policy.
        let second = ScreenInfo(
            id: ScreenID(rawValue: 2),
            frame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
            name: "Display 2",
            displayID: CGDirectDisplayID(43))
        let secondSpace = SpaceID(rawValue: 102)
        harness = ControllerHarness(
            screens: [Self.screen, second],
            activeSpaces: [
                Self.screen.displayID: Self.spaceA,
                second.displayID: secondSpace,
            ],
            deathConfirmation: 0)
        harness.fireCursorMove(to: CGPoint(x: 2000, y: 500))
        gateway.clearWrites()
        let birth = CGRect(x: 4000, y: 3000, width: 800, height: 600)

        let handle = gateway.simulateWindowCreated(frame: birth)

        XCTAssertEqual(
            gateway.frame(of: handle), birth, "a birth keeps its frame")
        let id = controller.registeredID(for: handle)!
        XCTAssertNotNil(
            controller.canvas(
                for: TilingSpaceKey(screen: second.id, space: secondSpace)
            ).record(of: id),
            "the birth record lives on the cursor display's canvas")
        XCTAssertNil(
            controller.canvas(
                for: TilingSpaceKey(screen: Self.screen.id, space: Self.spaceA)
            ).record(of: id),
            "the main display's canvas claims nothing")
    }

    func testBirthAfterSwipeRecordsOnTheActiveCanvas() {
        // Swiped to Space B, a window opens: the record lands on the
        // active canvas, with no write and no parked restore.
        let secondSpace = SpaceID(rawValue: 102)
        gateway.activeSpaces[Self.screen.displayID] = secondSpace
        gateway.simulateSpaceChange()
        gateway.clearWrites()
        let birth = CGRect(x: 10, y: 10, width: 800, height: 600)

        let handle = gateway.simulateWindowCreated(frame: birth)

        XCTAssertEqual(gateway.frame(of: handle), birth)
        let id = controller.registeredID(for: handle)!
        let key = TilingSpaceKey(screen: Self.screen.id, space: secondSpace)
        XCTAssertNotNil(controller.canvas(for: key).record(of: id))
        XCTAssertTrue(
            controller.canvas(for: key).deferredRestores.isEmpty,
            "a birth parks no restore")
    }
}

/// The canvas exits that share the sizing: drag-out and hidden-Space
/// untile leave the sized footprint through the same write policy.
final class UntiledExitTests: XCTestCase {
    private static let screen = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        name: "Display 1",
        displayID: CGDirectDisplayID(42))

    private static let secondScreen = ScreenInfo(
        id: ScreenID(rawValue: 2),
        frame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
        name: "Display 2",
        displayID: CGDirectDisplayID(43))

    private static let spaceA = SpaceID(rawValue: 101)
    private static let spaceB = SpaceID(rawValue: 102)
    private static let secondDisplaySpace = SpaceID(rawValue: 202)

    private var harness: ControllerHarness!
    private var gateway: FakeWindowGateway { harness.gateway }
    private var controller: TilingController { harness.controller }
    private var canvas: TilingSpace { harness.canvas }

    override func setUp() {
        super.setUp()
        harness = ControllerHarness(
            screens: [Self.screen],
            activeSpaces: [Self.screen.displayID: Self.spaceA],
            deathConfirmation: 0)
    }

    func testDragOutDropIsSizedToQuarter() {
        // Two stacked sixths; b is dragged out and dropped at (300, 400).
        // The drop's top edge takes the quarter footprint, the freed cells
        // still reflow into the survivor, and the growth still shares one
        // undo chapter.
        let a = harness.addFocusedWindow(frame: CGRect(x: 12, y: 34, width: 500, height: 400))
        controller.handle(slot: .sixthTopLeft)
        let b = harness.addFocusedWindow(frame: CGRect(x: 40, y: 500, width: 600, height: 300))
        controller.handle(slot: .sixthBottomLeft)
        let aID = controller.registeredID(for: a)!
        let bID = controller.registeredID(for: b)!
        _ = gateway.setFrame(b, to: CGRect(x: 300, y: 400, width: 500, height: 300))

        controller.untileFromDrag(bID)

        let landed = gateway.frame(of: b)!
        XCTAssertEqual(landed, CGRect(x: 300, y: 200, width: 800, height: 500))
        XCTAssertEqual(
            canvas.state.slot(of: aID), .sixthLeft, "the freed cells still reflow")
        XCTAssertEqual(canvas.undoStack.count, 1, "the reflow still shares one chapter")
    }

    func testDragOutDroppedOnAnotherDisplayKeepsTheDropOrigin() {
        // The audited A5: a window tiled on display 1, dragged to display
        // 2, and dropped at x≈1700 was pinned back to display 1's right
        // edge (x≈800) and sized against display 1. The drop display owns
        // the floating frame: the window keeps its drop origin and takes
        // that display's quarter, while the slot release, reflow, and undo
        // chapter stay on the canvas that owned the window.
        harness = ControllerHarness(
            screens: [Self.screen, Self.secondScreen],
            activeSpaces: [
                Self.screen.displayID: Self.spaceA,
                Self.secondScreen.displayID: Self.secondDisplaySpace,
            ],
            deathConfirmation: 0)
        let a = harness.addFocusedWindow(frame: CGRect(x: 12, y: 34, width: 500, height: 400))
        controller.handle(slot: .sixthTopLeft)
        let b = harness.addFocusedWindow(frame: CGRect(x: 40, y: 500, width: 600, height: 300))
        controller.handle(slot: .sixthBottomLeft)
        let aID = controller.registeredID(for: a)!
        let bID = controller.registeredID(for: b)!

        // The drop lands on display 2, past display 1's right edge.
        _ = gateway.setFrame(b, to: CGRect(x: 1700, y: 100, width: 800, height: 600))
        gateway.clearWrites()

        controller.untileFromDrag(bID)

        XCTAssertEqual(
            gateway.frame(of: b),
            CGRect(x: 1700, y: 200, width: 800, height: 500),
            "the drop display's quarter at the drop origin, not display 1's edge")
        let origin = TilingSpaceKey(screen: Self.screen.id, space: Self.spaceA)
        let drop = TilingSpaceKey(
            screen: Self.secondScreen.id, space: Self.secondDisplaySpace)
        XCTAssertNil(
            controller.canvas(for: origin).state.slot(of: bID),
            "the slot releases on the origin canvas")
        XCTAssertEqual(
            controller.canvas(for: origin).state.slot(of: aID), .sixthLeft,
            "the freed cells still reflow on the origin canvas")
        XCTAssertEqual(
            controller.canvas(for: origin).undoStack.count, 1,
            "the undo chapter stays on the origin canvas")
        XCTAssertNil(
            controller.canvas(for: drop).record(of: bID),
            "the drop canvas holds no record: the window is not migrated")
        XCTAssertTrue(
            controller.canvas(for: drop).state.occupants.isEmpty,
            "the drop canvas gains no occupancy")
        XCTAssertEqual(
            gateway.writes.filter { $0.handle == b }.count, 1,
            "one drag-out, one floating write: the window is not emitted twice")
    }

    func testSwitchToSixthsFloatsAtQuarterSize() {
        // Quarters -> sixths: every window still lands at the quarter
        // footprint, and one undo restores the windows and the layout.
        let a = harness.addFocusedWindow(frame: CGRect(x: 12, y: 34, width: 500, height: 400))
        controller.handle(slot: .topLeft)
        let b = harness.addFocusedWindow(frame: CGRect(x: 900, y: 50, width: 600, height: 450))
        controller.handle(slot: .topRight)

        controller.handleSwitchLayout(to: .sixths)

        XCTAssertEqual(canvas.state.layout, .sixths)
        XCTAssertTrue(canvas.state.occupants.isEmpty)
        XCTAssertEqual(
            gateway.frame(of: a), CGRect(x: 12, y: 0, width: 800, height: 500))
        XCTAssertEqual(
            gateway.frame(of: b), CGRect(x: 800, y: 0, width: 800, height: 500))

        XCTAssertTrue(controller.undoLastDisplacement())
        XCTAssertEqual(canvas.state.layout, .quarters, "undo restores the layout")
        XCTAssertNotNil(canvas.state.occupant(of: .topLeft), "a returns to its quad")
        XCTAssertNotNil(canvas.state.occupant(of: .topRight), "b returns to its quad")
        XCTAssertEqual(canvas.state.tiledWindows.count, 2)
    }

    func testUntileRefreshesStaleCanvasGeometry() {
        // Tiled on the old geometry, then the visible frame shrank with
        // no display-change notification: untiling restores from the live
        // frame, not the stored one.
        let handle = harness.addFocusedWindow(
            frame: CGRect(x: 100, y: 100, width: 700, height: 900))
        controller.handle(slot: .sixthTopLeft)
        let id = controller.registeredID(for: handle)!
        harness.screens = [ScreenInfo(
            id: Self.screen.id,
            frame: Self.screen.frame,
            visibleFrame: CGRect(x: 0, y: 50, width: 1600, height: 950),
            name: Self.screen.name,
            displayID: Self.screen.displayID)]

        _ = controller.untile(window: id)

        XCTAssertEqual(
            gateway.frame(of: handle),
            CGRect(x: 100, y: 525, width: 800, height: 475),
            "an untile restores from the live visible frame")
    }

    func testSizedUntileOnHiddenSpaceDefers() {
        // Tiled on Space A, then swiped to B: untiling defers the sized
        // restore instead of dragging the window through Mission Control.
        // The deferral stands (never a refusal), and the sized frame
        // lands on the swipe back.
        let handle = harness.addFocusedWindow(frame: CGRect(x: 12, y: 34, width: 500, height: 400))
        controller.handle(slot: .sixthTopLeft)
        let id = controller.registeredID(for: handle)!
        let tiled = gateway.frame(of: handle)!
        gateway.activeSpaces[Self.screen.displayID] = Self.spaceB
        gateway.simulateSpaceChange()
        gateway.clearWrites()

        let receipt = controller.untile(window: id)

        XCTAssertFalse(
            gateway.writes.contains { $0.handle == handle },
            "a hidden Space is never written blind")
        XCTAssertEqual(
            gateway.frame(of: handle), tiled,
            "a deferred restore leaves the window where it was")
        XCTAssertTrue(receipt.performed, "a deferral stands, never a refusal")
        XCTAssertNil(
            controller.canvas(for: TilingSpaceKey(screen: Self.screen.id, space: Self.spaceA)).error)

        gateway.activeSpaces[Self.screen.displayID] = Self.spaceA
        gateway.simulateSpaceChange()

        let landed = gateway.frame(of: handle)!
        XCTAssertEqual(landed, CGRect(x: 12, y: 0, width: 800, height: 500),
            "the deferred restore lands sized on return")
    }
}
