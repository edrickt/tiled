import CoreGraphics
import XCTest
@testable import tiled

/// Regression pins for the audit's engine/controller findings.
///
/// The undo path re-enters `TilingState` directly instead of going through
/// `plan`, so these tests hold it to the plan rules: no cell double-booking,
/// no two layouts on one canvas. They also pin the failure narratives:
/// a refused requester must not move a re-house victim, must not drop the
/// evictees it restored, and must not leave a chapter with nothing in it.
final class UndoIntegrityTests: XCTestCase {
    private static let main = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        name: "Display 1")

    private var gateway: FakeWindowGateway!
    private var controller: TilingController!
    private var feedbacks: [TilingController.Feedback] = []

    /// The canvas the test's single display tiles onto: reads go through
    /// the same accessor actions do.
    private var canvas: TilingSpace { controller.canvas(for: controller.focusedTilingSpace) }

    /// One canvas of a controller built inside a test (the setup
    /// controller is not always the one acting).
    private func localCanvas(_ controller: TilingController) -> TilingSpace {
        controller.canvas(for: controller.focusedTilingSpace)
    }

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        controller = TilingController(
            gateway: gateway, pruneInterval: nil, deathConfirmation: 0)
        controller.onFeedback = { [weak self] in self?.feedbacks.append($0) }
    }

    @discardableResult
    private func focusNewWindow(
        _ frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)
    ) -> WindowHandle {
        let handle = gateway.addWindow(frame: frame)
        gateway.focused = handle
        return handle
    }

    /// The union of all tiled cells on the focused canvas: undo may never
    /// make one cell belong to two windows.
    private var doubledCells: [TileCell] {
        var seen: Set<TileCell> = []
        var doubled: [TileCell] = []
        for slot in canvas.state.occupants.keys {
            for cell in slot.cells {
                if !seen.insert(cell).inserted { doubled.append(cell) }
            }
        }
        return doubled
    }

    // MARK: Undo vs. the plan rules

    func testUndoReturnsAStepAsideBlockerToItsEvictionSlot() {
        // a holds the left half; b's top-left request steps a aside into
        // the bottom-left quad (chapter: a -> leftHalf, requester b);
        // c's bottom-left request then evicts a plainly from its
        // step-aside slot (chapter: a -> bottomLeft, requester c). Undo
        // must return a to the slot it was evicted from — the bottom-
        // left quad, not its original half — release c, and book no
        // cell twice: b's top-left quad never overlaps a's return.
        // (Before the step-aside rule existed, b's request untiled a
        // and this chapter dance instead pinned undo stepping c aside
        // out of a's returning half.)
        let a = focusNewWindow()
        controller.handle(slot: .leftHalf)
        let b = focusNewWindow(CGRect(x: 50, y: 50, width: 700, height: 500))
        controller.handle(slot: .topLeft)
        let c = focusNewWindow(CGRect(x: 60, y: 60, width: 600, height: 400))
        controller.handle(slot: .bottomLeft)

        controller.undoLastDisplacement()

        XCTAssertTrue(doubledCells.isEmpty, "undo left cells double-booked")
        XCTAssertEqual(
            canvas.state.occupant(of: .bottomLeft), 1,
            "a returns to the slot it was evicted from, its step-aside quad")
        XCTAssertNil(canvas.state.slot(of: 3), "c's request is undone and c releases")
        XCTAssertEqual(
            gateway.frame(of: c), CGRect(x: 60, y: 60, width: 600, height: 400),
            "c restored to its pre-tile frame")
        XCTAssertEqual(canvas.state.slot(of: 2), .topLeft, "b keeps the quad it stepped into")
        XCTAssertEqual(canvas.state.tiledWindows.count, 2)
    }

    func testUndoOfLayoutSwitchDisplacesTheOtherLayoutsOccupants() {
        let a = focusNewWindow()
        controller.handle(slot: .topLeft) // quarters
        let b = focusNewWindow(CGRect(x: 50, y: 50, width: 700, height: 500))
        controller.handle(slot: .sixthTopLeft) // switch; chapter: a -> topLeft
        let c = focusNewWindow(CGRect(x: 60, y: 60, width: 600, height: 400))
        controller.handle(slot: .sixthBottomRight) // sixths, no chapter

        controller.undoLastDisplacement()

        XCTAssertEqual(
            canvas.state.activeLayout, .quarters,
            "the restored chapter's layout owns the canvas again")
        XCTAssertNotNil(canvas.state.occupant(of: .topLeft), "a returns")
        XCTAssertNil(canvas.state.occupant(of: .sixthBottomRight))
        XCTAssertNil(canvas.state.slot(of: 3), "c was untiled out of the abandoned layout")
        XCTAssertEqual(
            gateway.frame(of: c), CGRect(x: 60, y: 60, width: 600, height: 400),
            "c restored to its pre-tile frame")
        XCTAssertEqual(canvas.state.tiledWindows.count, 1)
    }

    // MARK: Refused requesters

    func testRefusedPlacementWithReHouseDoesNotMoveTheVictim() {
        // Right third, middle third, and bottom-left sixth occupied; the
        // right third requests the right two-thirds and its app refuses.
        // The re-house must not happen: without the requester's placement
        // there is no room to make and no chapter to promise.
        focusNewWindow(CGRect(x: 10, y: 10, width: 400, height: 300))
        controller.handle(slot: .sixthBottomLeft)
        let middle = focusNewWindow(CGRect(x: 20, y: 20, width: 400, height: 300))
        controller.handle(slot: .sixthMiddle)
        let right = focusNewWindow(CGRect(x: 30, y: 30, width: 400, height: 300))
        controller.handle(slot: .sixthRight)

        gateway.refuseNextWrites(right)
        controller.handle(slot: .sixthsRightTwoThirds)

        XCTAssertNotNil(canvas.error, "the refusal is reported")
        XCTAssertNil(canvas.state.slot(of: 2), "the evictee went home, not to a new tile")
        XCTAssertEqual(
            gateway.frame(of: middle), CGRect(x: 20, y: 20, width: 400, height: 300),
            "the victim's frame is its pre-tile frame")
        XCTAssertFalse(
            canvas.notice?.contains("to make room") ?? false,
            "no re-house notice for a request that never landed")
        XCTAssertFalse(canvas.undoStack.isEmpty, "the eviction itself is undoable")

        controller.undoLastDisplacement()
        XCTAssertNotNil(
            canvas.state.occupant(of: .sixthMiddle),
            "undo returns the evictee to the slot it left")
    }

    func testRefusedPlacementAfterEvictionsKeepsTheDestructionUndoable() {
        let w = focusNewWindow()
        controller.handle(slot: .topLeft)
        let x = focusNewWindow(CGRect(x: 40, y: 40, width: 500, height: 400))

        gateway.refuseNextWrites(x)
        controller.handle(slot: .leftHalf) // evicts w, then refuses x

        XCTAssertNil(canvas.state.slot(of: 1), "w was evicted by the failed request")
        XCTAssertEqual(
            gateway.frame(of: w), CGRect(x: 0, y: 0, width: 800, height: 600),
            "w went back to its pre-tile frame")
        XCTAssertNotNil(canvas.notice, "the eviction is narrated, not silent")
        XCTAssertFalse(canvas.undoStack.isEmpty, "the eviction is undoable")

        controller.undoLastDisplacement()
        XCTAssertNotNil(canvas.state.occupant(of: .topLeft), "undo re-tiles w")
    }

    func testRefusedPlacementAfterSwitchKeepsTheDestructionUndoable() {
        // The switch mirror of the eviction case above: a quarters
        // arrangement is untiled by a sixths request whose placement the
        // requester's app refuses. The refusal and the mass untile's
        // chapter coexist exactly as the tile branch's pinned behaviour
        // prescribes — the destruction is narrated, not silent, and one
        // undo brings every untiled window home.
        let w = focusNewWindow()
        controller.handle(slot: .topLeft)
        let x = focusNewWindow(CGRect(x: 40, y: 40, width: 500, height: 400))

        gateway.refuseNextWrites(x)
        controller.handle(slot: .sixthLeft) // switch untiles w, then refuses x

        XCTAssertNil(canvas.state.slot(of: 1), "w was untiled by the failed switch")
        XCTAssertEqual(
            gateway.frame(of: w), CGRect(x: 0, y: 0, width: 800, height: 600),
            "w went back to its pre-tile frame")
        XCTAssertNotNil(canvas.notice, "the untile is narrated, not silent")
        XCTAssertNotNil(canvas.error, "the refused placement is surfaced")
        XCTAssertFalse(canvas.undoStack.isEmpty, "the destruction is undoable")

        controller.undoLastDisplacement()
        XCTAssertNotNil(canvas.state.occupant(of: .topLeft), "undo re-tiles w")
    }

    // MARK: Partial restoration

    func testPartialUndoFailureReachesTheUser() {
        // Two windows are evicted by a layout switch; one refuses its
        // restore. The chapter partly restored, but the refusal must
        // reach the user instead of hiding behind "1 window restored".
        let a = focusNewWindow()
        controller.handle(slot: .topLeft)
        focusNewWindow(CGRect(x: 900, y: 50, width: 600, height: 450))
        controller.handle(slot: .topRight)
        focusNewWindow(CGRect(x: 1200, y: 80, width: 500, height: 400))
        controller.handle(slot: .sixthLeft)

        gateway.refuseNextWrites(a)
        XCTAssertFalse(
            controller.undoLastDisplacement(),
            "a refused frame means the chapter did not fully restore")

        XCTAssertNil(canvas.notice, "a partial failure must not be narrated as success")
        XCTAssertEqual(
            canvas.error,
            "Couldn't restore \u{201C}TestApp\u{201D}: it may still be sitting in its old tile.")
    }

    func testRefusedRequesterRestoreReachesTheUser() {
        // A swap's requester restores to its pre-tile frame before its
        // chapter entry re-tiles it; when that first write is refused,
        // the refusal is part of the chapter's story, not swallowed.
        let a = focusNewWindow()
        controller.handle(slot: .topLeft)
        focusNewWindow(CGRect(x: 900, y: 50, width: 600, height: 450))
        controller.handle(slot: .bottomLeft)
        focusNewWindow(CGRect(x: 900, y: 0, width: 800, height: 600))
        controller.handle(slot: .rightHalf)
        gateway.focused = a
        controller.handle(slot: .rightHalf)

        gateway.refuseNextWrites(a)
        XCTAssertFalse(
            controller.undoLastDisplacement(),
            "the refused requester frame means the chapter did not fully restore")

        XCTAssertNil(canvas.notice)
        XCTAssertEqual(
            canvas.error,
            "Couldn't restore \u{201C}TestApp\u{201D}: it may still be sitting in its old tile.")
    }

    func testUndoNoticeCountsOnlyRestoredWindows() {
        // A chapter of two whose first evictee died before the undo: the
        // notice reports the one window that actually returned, not the
        // chapter's original size.
        let a = focusNewWindow()
        controller.handle(slot: .topLeft)
        focusNewWindow(CGRect(x: 900, y: 50, width: 600, height: 450))
        controller.handle(slot: .topRight)
        focusNewWindow(CGRect(x: 1200, y: 80, width: 500, height: 400))
        controller.handle(slot: .sixthLeft)
        gateway.kill(a)

        XCTAssertTrue(controller.undoLastDisplacement())

        XCTAssertEqual(canvas.notice, "Undid displacement \u{00B7} 1 window restored.")
        XCTAssertNil(canvas.error)
    }

    // MARK: Re-house region and empty chapters

    func testReHouseUsesTheRegionTheRequestActuallyLeavesFree() {
        // Left two-thirds + right sixth occupied; the left two-thirds
        // requests the right two-thirds. After the request the free cells
        // are exactly the left third, so the evicted right sixth should
        // re-house there instead of untangling.
        let left = focusNewWindow()
        controller.handle(slot: .sixthsLeftTwoThirds)
        let right = focusNewWindow(CGRect(x: 50, y: 50, width: 500, height: 400))
        controller.handle(slot: .sixthRight)
        gateway.focused = left

        controller.handle(slot: .sixthsRightTwoThirds)

        XCTAssertEqual(canvas.state.slot(of: 2), .sixthLeft, "the evictee re-tiles")
        XCTAssertEqual(canvas.state.occupant(of: .sixthLeft), 2)
        XCTAssertTrue(
            canvas.notice?.contains("to make room") ?? false,
            "the move is narrated as a re-house")
        XCTAssertNil(canvas.error, "no error on a clean re-house")

        controller.undoLastDisplacement()
        XCTAssertEqual(
            canvas.state.occupant(of: .sixthRight), 2,
            "undo returns the victim to the slot it was evicted from")
        XCTAssertNil(canvas.state.occupant(of: .sixthLeft))
        XCTAssertNil(
            canvas.state.slot(of: 1),
            "the requester's id was reissued by the shared undo machinery")
        XCTAssertNotNil(
            canvas.state.occupant(of: .sixthsLeftTwoThirds),
            "the tiled requester returns to the slot it vacated")
    }

    func testUntileAllDropsAChapterItCouldNotRebuild() {
        let a = focusNewWindow()
        controller.handle(slot: .topLeft)
        let b = focusNewWindow(CGRect(x: 50, y: 50, width: 700, height: 500))
        controller.handle(slot: .topRight)
        // Every frame read fails: the restore writes still succeed (the
        // stored pre-tile frames are all the restore needs), but no
        // snapshot entry can be rebuilt from the live frames.
        gateway.hideFrames = [a, b]

        controller.untileAll()

        XCTAssertNil(canvas.state.slot(of: 1))
        XCTAssertNil(canvas.state.slot(of: 2))
        XCTAssertFalse(
            !canvas.undoStack.isEmpty,
            "no chapter can restore windows whose frames never read")
        XCTAssertFalse(
            canvas.notice?.contains("to undo") ?? false,
            "the notice must not offer a key with no chapter behind it")
    }

    // MARK: Refusal attribution and off-Space writes

    func testRefusalLandsOnTheActingCanvasNotTheFocusedOne() {
        let left = Self.main
        let right = ScreenInfo(
            id: ScreenID(rawValue: 2),
            frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            name: "Display 2")
        let screens = [left, right]
        let localGateway = FakeWindowGateway()
        let localController = TilingController(
            gateway: localGateway, pruneInterval: nil,
            screens: { screens }, deathConfirmation: 0)
        let leftHandle = localGateway.addWindow(frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        localGateway.focused = leftHandle
        localController.handle(slot: .topLeft)
        let rightHandle = localGateway.addWindow(
            frame: CGRect(x: 2000, y: 100, width: 800, height: 600))
        localGateway.focused = rightHandle
        localController.handle(slot: .topLeft)

        // Focus stays on the left display and the right window's restore
        // is refused: the message belongs to the right canvas.
        localGateway.focused = leftHandle
        localGateway.refuseNextWrites(rightHandle)
        localController.untile(window: 2)

        XCTAssertNil(
            localController.canvas(for: left.id).error,
            "the focused canvas did not act and must not carry the message")
        XCTAssertNotNil(
            localController.canvas(for: right.id).error,
            "the acting canvas carries the refusal")
    }

    // MARK: Adapter cleanup contract and transient death

    func testConfirmedDeathReleasesTheHandleButUntileDoesNot() {
        focusNewWindow()
        controller.handle(slot: .topLeft)
        let b = focusNewWindow(CGRect(x: 50, y: 50, width: 700, height: 500))
        controller.handle(slot: .topRight)

        controller.untile(window: 1)
        XCTAssertTrue(
            gateway.releaseCalls.isEmpty,
            "an undoable departure keeps its element for the restore")

        gateway.probeDead.insert(b)
        controller.pruneDeadWindows() // deathConfirmation 0 confirms at once
        XCTAssertEqual(gateway.releaseCalls, [b], "confirmed death hands the handle back")
    }

    func testDestroyNotificationReleasesTheHandle() {
        let a = focusNewWindow()
        controller.handle(slot: .topLeft)
        gateway.kill(a)
        gateway.simulateDestroyed(a)

        XCTAssertEqual(gateway.releaseCalls, [a])
        XCTAssertNil(canvas.state.slot(of: 1))
    }

    func testTransientDeadReadingRecoversBeforeTheConfirmationWindow() {
        var clock = Date(timeIntervalSince1970: 0)
        let localGateway = FakeWindowGateway()
        let localController = TilingController(
            gateway: localGateway, pruneInterval: nil,
            deathConfirmation: 3, now: { clock })
        let a = localGateway.addWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        localGateway.focused = a
        localController.handle(slot: .topLeft)

        // One dead reading marks a pending death, never a release: the
        // element must stay probe-able for the recovery the controller
        // promises (the lid-close transient).
        localGateway.probeDead.insert(a)
        localController.pruneDeadWindows()
        XCTAssertEqual(localCanvas(localController).state.occupant(of: .topLeft), 1)
        XCTAssertTrue(localGateway.releaseCalls.isEmpty)

        // The probe answers again inside the confirmation window.
        localGateway.probeDead.remove(a)
        clock = clock.addingTimeInterval(1)
        localController.pruneDeadWindows()
        XCTAssertEqual(
            localCanvas(localController).state.occupant(of: .topLeft), 1,
            "the transient recovered")
        XCTAssertTrue(localGateway.releaseCalls.isEmpty)

        // A sustained dead reading confirms and releases.
        localGateway.probeDead.insert(a)
        localController.pruneDeadWindows()
        clock = clock.addingTimeInterval(4)
        localController.pruneDeadWindows()
        XCTAssertNil(localCanvas(localController).state.occupant(of: .topLeft))
        XCTAssertEqual(localGateway.releaseCalls, [a])
    }

    // MARK: Partial writes and write counts

    func testPartialSizeRefusalLeavesNoCommittedState() {
        focusNewWindow()
        controller.handle(slot: .topLeft)
        let preWrite = CGRect(x: 40, y: 40, width: 500, height: 400)
        let x = focusNewWindow(preWrite)
        gateway.refuseSizeWrites.insert(x)

        controller.handle(slot: .leftHalf)

        XCTAssertNil(canvas.state.slot(of: 2), "state never commits a refused placement")
        XCTAssertEqual(
            gateway.frame(of: x), preWrite,
            "the landed origin is put back with the untouched size: left whole")
        XCTAssertNotNil(canvas.error)
        XCTAssertTrue(
            gateway.writes.contains { $0.handle == x },
            "the partial write is observable instead of indistinguishable from a refusal")
    }

    func testPartialPositionRefusalRestoresThePreWriteFrame() {
        // The mirror half-apply: the position write fails on every
        // attempt while the size lands. The window must not stay resized
        // at its old origin while the app is blamed for a refusal and
        // state rolls back — the screen disagreeing with both.
        focusNewWindow()
        controller.handle(slot: .topLeft)
        let preWrite = CGRect(x: 40, y: 40, width: 500, height: 400)
        let x = focusNewWindow(preWrite)
        gateway.refusePositionWrites.insert(x)

        controller.handle(slot: .leftHalf)

        XCTAssertEqual(
            gateway.frame(of: x), preWrite,
            "the landed size is put back with the untouched origin: left whole")
        XCTAssertNil(canvas.state.slot(of: 2), "the write reads as refused")
        XCTAssertNotNil(canvas.error, "the refusal surfaces on the canvas")
    }

    func testRetilingOwnSlotIssuesNoFrameWrite() {
        focusNewWindow()
        controller.handle(slot: .topLeft)
        gateway.clearWrites()

        controller.handle(slot: .topLeft)

        XCTAssertTrue(gateway.writes.isEmpty, "a same-slot request reasserts nothing")
    }

    // MARK: Withheld-Space canvases

    private func makeWithheldSpaceController()
        -> (gateway: FakeWindowGateway, controller: TilingController,
            key: TilingSpaceKey, displayID: CGDirectDisplayID)
    {
        let displayID: CGDirectDisplayID = 42
        let screen = ScreenInfo(
            id: ScreenID(rawValue: 1),
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            name: "Display 1",
            displayID: displayID)
        let gateway = FakeWindowGateway() // activeSpaces empty: the id is withheld
        let controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            screens: { [screen] }, deathConfirmation: 0)
        // The canvas windows tiled onto while the Space id was unknown:
        // an explicit key, because the resolved id names a different one.
        let key = TilingSpaceKey(screen: screen.id, space: nil)
        return (gateway, controller, key, displayID)
    }

    func testWindowTiledWhileTheSpaceWasWithheldStaysReachable() {
        let (gateway, controller, key, displayID) = makeWithheldSpaceController()
        let a = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .topLeft)

        // The Space table answers with an id after the fact.
        gateway.activeSpaces = [displayID: SpaceID(rawValue: 101)]

        XCTAssertTrue(
            controller.tiledWindowsInfo.contains { $0.id == 1 },
            "the manage list still reaches the withheld canvas")
        XCTAssertEqual(
            controller.focusedTiledWindowsInfo.count, 1,
            "the focused canvas stays the withheld one")
        controller.untileAll()
        XCTAssertNil(
            controller.canvas(for: key).state.slot(of: 1),
            "Untile All reaches the withheld canvas")
    }

    func testUndoReachesChaptersPushedWhileTheSpaceWasWithheld() {
        let (gateway, controller, key, displayID) = makeWithheldSpaceController()
        let a = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        gateway.focused = a
        controller.handle(slot: .topLeft)
        let b = gateway.addWindow(frame: CGRect(x: 50, y: 50, width: 700, height: 500))
        gateway.focused = b
        controller.handle(slot: .topLeft) // evicts a; chapter on the withheld canvas

        gateway.activeSpaces = [displayID: SpaceID(rawValue: 101)]
        controller.undoLastDisplacement()

        let canvas = controller.canvas(for: key)
        XCTAssertNotNil(canvas.state.occupant(of: .topLeft), "the evicted window returned")
        XCTAssertNil(canvas.state.slot(of: 2), "the requester was released by the undo")
        XCTAssertTrue(canvas.undoStack.isEmpty, "the withheld chapter was consumed")
    }

    func testExpandDefersAnOffSpaceWindowInsteadOfWritingIt() {
        let displayID: CGDirectDisplayID = 42
        let spaceA = SpaceID(rawValue: 101)
        let spaceB = SpaceID(rawValue: 102)
        let screen = ScreenInfo(
            id: ScreenID(rawValue: 1),
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            name: "Display 1",
            displayID: displayID)
        let localGateway = FakeWindowGateway()
        localGateway.activeSpaces = [displayID: spaceA]
        let localController = TilingController(
            gateway: localGateway, pruneInterval: nil,
            screens: { [screen] }, deathConfirmation: 0)
        var localFeedbacks: [TilingController.Feedback] = []
        localController.onFeedback = { localFeedbacks.append($0) }
        let handle = localGateway.addWindow(frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        localGateway.focused = handle
        localController.handle(slot: .topLeft)
        let original = localGateway.frame(of: handle)

        // The window's canvas is not the visible Space: the expand write
        // must wait for the swipe back, exactly like every other write.
        localGateway.activeSpaces = [displayID: spaceB]
        localGateway.simulateSpaceChange()
        localGateway.focused = handle
        localController.handleExpandToggle()

        XCTAssertEqual(
            localGateway.frame(of: handle), original,
            "an off-Space window is never written")
        XCTAssertTrue(
            localFeedbacks.isEmpty,
            "a deferred write is not reported as an app refusal, got \(localFeedbacks)")
    }
}
