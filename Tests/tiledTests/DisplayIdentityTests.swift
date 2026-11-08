import AppKit
import CoreGraphics
import XCTest

@testable import tiled

/// Display identity across screen-provider changes: a physical display's
/// canvas must survive list reordering, primary-display changes,
/// unplug/replug, and a display-number change (sleep/wake, dock change,
/// cable replug). Other per-display tests keep `ScreenID` fixed, so they
/// cannot catch an identity derived from `NSScreen.screens` order or from
/// the transient CoreGraphics display number.
final class DisplayIdentityTests: XCTestCase {
    private static let leftFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private static let rightFrame = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
    private static let leftDisplayID: CGDirectDisplayID = 101
    private static let rightDisplayID: CGDirectDisplayID = 202
    /// A display that returns with a new CoreGraphics number keeps its UUID.
    private static let renumberedLeftDisplayID: CGDirectDisplayID = 501
    private static let leftUUID = UUID(
        uuidString: "7A3C1B20-0D8E-4F52-9C61-2B4A5D6E7F80")!
    private static let rightUUID = UUID(
        uuidString: "1C2D3E4F-5061-4728-89AB-CDEF01234567")!
    /// A different physical display that takes over the old display number.
    private static let replacementUUID = UUID(
        uuidString: "9F8E7D6C-5B4A-4392-8170-6F5E4D3C2B1A")!
    private static let spaceA = SpaceID(rawValue: 11)
    private static let spaceB = SpaceID(rawValue: 12)
    private static let left = screen(
        displayID: leftDisplayID, uuid: leftUUID, frame: leftFrame,
        name: "Display 1")
    private static let right = screen(
        displayID: rightDisplayID, uuid: rightUUID, frame: rightFrame,
        name: "Display 2")
    private static let renumberedLeft = screen(
        displayID: renumberedLeftDisplayID, uuid: leftUUID, frame: leftFrame,
        name: "Display 1")

    private static func screen(
        displayID: CGDirectDisplayID,
        uuid: UUID?,
        fallbackIndex: Int = 0,
        frame: CGRect,
        name: String
    ) -> ScreenInfo {
        ScreenInfo(
            id: ScreenID(
                displayID: displayID, fallbackIndex: fallbackIndex, uuid: uuid),
            frame: frame,
            visibleFrame: frame,
            name: name,
            displayID: displayID)
    }

    /// A third display taking over the left display's old number with a
    /// different UUID: the left frame, but the replacement's identity.
    private static func replacement(
        for displayID: CGDirectDisplayID
    ) -> ScreenInfo {
        screen(
            displayID: displayID, uuid: replacementUUID,
            frame: leftFrame, name: "Replacement")
    }

    private func makeController(
        gateway: FakeWindowGateway,
        screens: @escaping () -> [ScreenInfo]
    ) -> TilingController {
        TilingController(
            gateway: gateway, pruneInterval: nil,
            screens: screens, deathConfirmation: 0,
            isMouseDown: { true })
    }

    @discardableResult
    private func addWindow(
        _ frame: CGRect, to gateway: FakeWindowGateway
    ) -> WindowHandle {
        let handle = gateway.addWindow(frame: frame)
        gateway.focused = handle
        return handle
    }

    private func screenChange() {
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func dragRightEdge(
        _ handle: WindowHandle, by delta: CGFloat, on gateway: FakeWindowGateway
    ) {
        var echo = gateway.frame(of: handle)!
        echo.size.width -= 10
        gateway.simulateChange(handle, to: echo)
        var dragged = gateway.frame(of: handle)!
        dragged.size.width += delta
        gateway.simulateChange(handle, to: dragged)
    }

    // MARK: Stable identity

    func testScreenIDKeysLiveIdentityOnTheUUIDAcrossARenumber() {
        let before = ScreenID(
            displayID: 101, fallbackIndex: 0, uuid: Self.leftUUID)
        let after = ScreenID(
            displayID: 501, fallbackIndex: 1, uuid: Self.leftUUID)

        XCTAssertEqual(
            before, after,
            "a display returning with a new number keeps one identity")
        XCTAssertEqual(
            before.hashValue, after.hashValue,
            "equal identities must hash alike")
        XCTAssertEqual(before.rawValue, 101, "the old number stays for logging")
        XCTAssertEqual(after.rawValue, 501, "the new number stays for logging")

        // The failure a UUID identity prevents: a renumber must find the
        // canvas a number-keyed dictionary table stored under the old key.
        let key = TilingSpaceKey(screen: before, space: Self.spaceA)
        let renumbered = TilingSpaceKey(screen: after, space: Self.spaceA)
        var canvases: [TilingSpaceKey: String] = [key: "kept"]
        XCTAssertEqual(
            canvases[renumbered], "kept",
            "a canvas table lookup after the renumber finds the equal key")
    }

    func testScreenIDNumberAndUUIDIdentitiesNeverCompareEqual() {
        let injected = ScreenID(rawValue: 101)
        let live = ScreenID(
            displayID: 101, fallbackIndex: 0, uuid: Self.leftUUID)
        let otherLive = ScreenID(
            displayID: 101, fallbackIndex: 0, uuid: Self.replacementUUID)

        XCTAssertNotEqual(
            injected, live,
            "an injected number identity is not the live display of that number")
        XCTAssertNotEqual(
            live, otherLive,
            "a reused display number with a different UUID is another display")
    }

    func testScreenIDKeysInjectedIdentityOnTheNumberNotListOrder() {
        let first = ScreenID(displayID: 42, fallbackIndex: 0)
        let rebuiltInAnotherOrder = ScreenID(displayID: 42, fallbackIndex: 99)

        XCTAssertEqual(
            first, rebuiltInAnotherOrder,
            "the same display number keeps one injected identity when the provider reorders")
        XCTAssertEqual(first.rawValue, 42)
    }

    func testScreenIDFallsBackToProviderIndexWithoutADisplayNumber() {
        XCTAssertEqual(ScreenID(displayID: 0, fallbackIndex: 3).rawValue, 3)
    }

    func testLiveScreenInfoUsesItsDisplayUUIDAsIdentity() throws {
        guard let live = NSScreen.screens.first else {
            throw XCTSkip("no display attached")
        }
        guard
            let number = live.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            number.uint32Value != 0,
            let cfUUID = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?
                .takeRetainedValue()
        else { throw XCTSkip("screen has no display number or UUID") }
        let uuid = try XCTUnwrap(
            UUID(uuidString: CFUUIDCreateString(nil, cfUUID) as String))

        let info = ScreenInfo(appKit: live, index: 4242)

        XCTAssertEqual(
            info.id,
            ScreenID(
                displayID: number.uint32Value, fallbackIndex: 4242, uuid: uuid),
            "the live provider keys identity on the persistent UUID, not on screen order")
        XCTAssertEqual(
            info.displayID, number.uint32Value,
            "displayID stays the live number the Space table reads")
    }

    // MARK: Reorder, unplug, replug

    func testProviderReorderKeepsEachCanvasWithItsPhysicalDisplay() {
        var current = [Self.left, Self.right]
        let gateway = FakeWindowGateway()
        let controller = makeController(gateway: gateway, screens: { current })

        let leftHandle = addWindow(
            CGRect(x: 100, y: 100, width: 800, height: 600), to: gateway)
        controller.handle(slot: .topLeft)
        let rightHandle = addWindow(
            CGRect(x: 2000, y: 100, width: 800, height: 600), to: gateway)
        controller.handle(slot: .topLeft)
        let leftTiled = gateway.frame(of: leftHandle)!
        let rightTiled = gateway.frame(of: rightHandle)!

        // Rebuilding the provider after a primary-display change reverses
        // the array; each entry still describes the same physical display.
        current = [Self.right, Self.left]
        screenChange()

        XCTAssertEqual(gateway.frame(of: leftHandle), leftTiled)
        XCTAssertEqual(gateway.frame(of: rightHandle), rightTiled)
        XCTAssertEqual(controller.canvas(for: Self.left.id).state.occupant(of: .topLeft), leftHandle.id)
        XCTAssertEqual(controller.canvas(for: Self.right.id).state.occupant(of: .topLeft), rightHandle.id)
    }

    func testUnpluggedDisplayKeepsItsCanvasForReplug() {
        var current = [Self.left, Self.right]
        let gateway = FakeWindowGateway()
        let controller = makeController(gateway: gateway, screens: { current })

        let leftHandle = addWindow(
            CGRect(x: 100, y: 100, width: 800, height: 600), to: gateway)
        controller.handle(slot: .topLeft)
        let rightHandle = addWindow(
            CGRect(x: 2000, y: 100, width: 800, height: 600), to: gateway)
        controller.handle(slot: .topLeft)

        // Give the right canvas a distinctive splitter state, so replug
        // has to restore more than the default screen geometry.
        dragRightEdge(rightHandle, by: -60, on: gateway)
        let movedGrid = controller.canvas(for: Self.right.id).grid
        XCTAssertNotEqual(movedGrid.columnSplit, 0.5)
        let draggedFrame = gateway.frame(of: rightHandle)!

        current = [Self.left]
        screenChange()
        XCTAssertEqual(
            gateway.frame(of: rightHandle), draggedFrame,
            "an unplugged display's window is not written in the dark")
        XCTAssertEqual(
            controller.canvas(for: Self.right.id).grid, movedGrid,
            "its canvas state survives the unplug")

        // Replug into the first provider slot: identity must come from the
        // display number, not the array index.
        current = [Self.right, Self.left]
        screenChange()
        XCTAssertEqual(
            gateway.frame(of: rightHandle),
            movedGrid.rect(for: .topLeft, in: Self.right.visibleFrame),
            "replug reasserts the kept canvas against the display's bounds")
        XCTAssertEqual(controller.canvas(for: Self.left.id).state.occupant(of: .topLeft), leftHandle.id)
    }

    /// An unplugged display's kept canvas must keep the geometry it had.
    /// Re-resolving it from the provider while its display is absent would
    /// write the main display's frame into the kept canvas, so the last-known
    /// frame survives until replug recomputes it.
    func testUnpluggedDisplayKeepsItsStoredVisibleFrameForReplug() {
        var current = [Self.left, Self.right]
        let gateway = FakeWindowGateway()
        let controller = makeController(gateway: gateway, screens: { current })

        let rightHandle = addWindow(
            CGRect(x: 2000, y: 100, width: 800, height: 600), to: gateway)
        controller.handle(slot: .topLeft)
        let kept = controller.canvas(for: Self.right.id).visibleFrame
        XCTAssertEqual(kept, Self.right.visibleFrame)

        // The right display goes away. Its kept canvas must not adopt the
        // main display's geometry: the last-known frame survives the unplug.
        current = [Self.left]
        screenChange()
        XCTAssertEqual(
            controller.canvas(for: Self.right.id).visibleFrame, kept,
            "an unplugged canvas keeps its last-known visible frame, not the main display's")

        // Replug re-resolves both canvases from their own restored displays.
        current = [Self.right, Self.left]
        screenChange()
        XCTAssertEqual(
            controller.canvas(for: Self.right.id).visibleFrame, Self.right.visibleFrame)
        XCTAssertEqual(
            controller.canvas(for: Self.left.id).visibleFrame, Self.left.visibleFrame)
        XCTAssertEqual(controller.canvas(for: Self.right.id).state.occupant(of: .topLeft), rightHandle.id)
    }

    // MARK: Renumber

    /// Sleep/wake, a dock change, or a cable replug can return the same
    /// physical display under a new CoreGraphics number. With the Space
    /// id unchanged, the canvas is the same canvas: its records, grid,
    /// splitters, undo chapter, and registered id must survive, and the
    /// next slot request must perform rather than defer off-Space.
    func testRenumberWithTheSameSpaceKeepsTheCanvasAndPerformsTheNextRequest() throws {
        var current = [Self.left]
        let gateway = FakeWindowGateway()
        gateway.activeSpaces = [Self.leftDisplayID: Self.spaceA]
        let controller = makeController(gateway: gateway, screens: { current })
        let key = TilingSpaceKey(screen: Self.left.id, space: Self.spaceA)

        let evicted = addWindow(
            CGRect(x: 100, y: 100, width: 800, height: 600), to: gateway)
        controller.handle(slot: .topLeft)
        let evictedID = try XCTUnwrap(controller.registeredID(for: evicted))
        let kept = addWindow(
            CGRect(x: 200, y: 200, width: 500, height: 400), to: gateway)
        controller.handle(slot: .topLeft)
        let keptID = try XCTUnwrap(controller.registeredID(for: kept))
        XCTAssertEqual(
            controller.canvas(for: key).undoStack.count, 1,
            "the eviction left one undo chapter on the canvas")

        dragRightEdge(kept, by: -60, on: gateway)
        let movedGrid = controller.canvas(for: key).grid
        XCTAssertNotEqual(movedGrid.columnSplit, 0.5)

        // The display returns under number 501, still showing the same
        // Space id.
        current = [Self.renumberedLeft]
        gateway.activeSpaces = [Self.renumberedLeftDisplayID: Self.spaceA]
        screenChange()
        let renumberedKey = TilingSpaceKey(
            screen: Self.renumberedLeft.id, space: Self.spaceA)

        XCTAssertEqual(
            controller.canvas(for: renumberedKey).state.occupant(of: .topLeft),
            keptID, "the renumbered display is the same canvas")
        XCTAssertEqual(
            controller.canvas(for: renumberedKey).grid, movedGrid,
            "the kept canvas's splitters survive the renumber")
        XCTAssertEqual(
            controller.canvas(for: renumberedKey).undoStack.count, 1,
            "the kept canvas's undo chapter survives the renumber")
        XCTAssertEqual(
            controller.registeredID(for: kept), keptID,
            "the kept record's registered id survives the renumber")
        XCTAssertNil(
            controller.registeredID(for: evicted), "the evicted window stays untiled")
        XCTAssertNil(
            controller.canvas(for: renumberedKey).state.slot(of: evictedID),
            "the evicted window's old slot stays empty after the renumber")

        // A request on the renumbered display's canvas performs and writes:
        // no deferral through a detached-screen key.
        gateway.focused = kept
        let receipt = controller.handle(slot: .topRight)
        XCTAssertTrue(receipt.performed)
        XCTAssertNil(receipt.announcement, "the request performed, it did not defer")
        XCTAssertEqual(
            controller.canvas(for: renumberedKey).state.slot(of: keptID), .topRight)
        XCTAssertEqual(
            gateway.frame(of: kept),
            movedGrid.rect(for: .topRight, in: Self.left.visibleFrame),
            "the request wrote against the kept canvas's splitters and geometry")
    }

    /// A renumber that also recreates the Mission Control Space no longer
    /// matches the canvas's key. The retired key must go through the
    /// existing vanished-canvas prune, and the next request must tile on
    /// the new Space's canvas instead of adopting the orphan.
    func testRenumberThatRecreatesTheSpaceRetiresTheCanvasThenRetiles() throws {
        var current = [Self.left]
        let gateway = FakeWindowGateway()
        gateway.activeSpaces = [Self.leftDisplayID: Self.spaceA]
        gateway.existingSpaceIDs = [Self.leftDisplayID: [Self.spaceA]]
        let controller = makeController(gateway: gateway, screens: { current })
        let oldKey = TilingSpaceKey(screen: Self.left.id, space: Self.spaceA)

        let window = addWindow(
            CGRect(x: 100, y: 100, width: 800, height: 600), to: gateway)
        controller.handle(slot: .topLeft)
        let oldID = try XCTUnwrap(controller.registeredID(for: window))
        XCTAssertNotNil(controller.canvas(for: oldKey).state.slot(of: oldID))

        // The display returns under number 501, and Mission Control shows
        // a newly created Space id there.
        current = [Self.renumberedLeft]
        gateway.activeSpaces = [Self.renumberedLeftDisplayID: Self.spaceB]
        gateway.existingSpaceIDs = [Self.renumberedLeftDisplayID: [Self.spaceB]]
        screenChange()
        controller.pruneDeadWindows()

        let newKey = TilingSpaceKey(
            screen: Self.renumberedLeft.id, space: Self.spaceB)
        XCTAssertTrue(
            controller.canvas(for: oldKey).records.isEmpty,
            "the vanished Space's canvas is retired, not kept as an orphan")
        XCTAssertNil(controller.registeredID(for: window), "the retired record is released")
        XCTAssertNil(
            controller.canvas(for: newKey).state.occupant(of: .topLeft),
            "the new Space's canvas does not adopt the retired canvas")

        gateway.focused = window
        let receipt = controller.handle(slot: .topRight)
        XCTAssertTrue(receipt.performed)
        let newID = try XCTUnwrap(controller.registeredID(for: window))
        XCTAssertEqual(controller.canvas(for: newKey).state.slot(of: newID), .topRight)
        XCTAssertEqual(
            gateway.frame(of: window),
            GridLayout().rect(for: .topRight, in: Self.left.visibleFrame),
            "the window tiles on the Space's own canvas")
    }

    /// The OS may hand an old display number to a different physical
    /// display. Identity is the UUID, so the new display starts empty and
    /// the old display's canvas stays intact for its own replug.
    func testReusedDisplayNumberWithANewUUIDDoesNotAdoptTheOldCanvas() throws {
        var current = [Self.left]
        let gateway = FakeWindowGateway()
        gateway.activeSpaces = [Self.leftDisplayID: Self.spaceA]
        let controller = makeController(gateway: gateway, screens: { current })
        let oldKey = TilingSpaceKey(screen: Self.left.id, space: Self.spaceA)

        let old = addWindow(
            CGRect(x: 100, y: 100, width: 800, height: 600), to: gateway)
        controller.handle(slot: .topLeft)
        let oldID = try XCTUnwrap(controller.registeredID(for: old))

        let replacement = Self.replacement(for: Self.leftDisplayID)
        current = [replacement]
        screenChange()
        let replacementKey = TilingSpaceKey(
            screen: replacement.id, space: Self.spaceA)

        XCTAssertNil(
            controller.canvas(for: replacementKey).state.occupant(of: .topLeft),
            "the replacement display's number does not adopt the old canvas")
        XCTAssertEqual(
            controller.canvas(for: oldKey).state.occupant(of: .topLeft), oldID,
            "the old display keeps its canvas for its own replug")
        XCTAssertEqual(controller.registeredID(for: old), oldID)

        let fresh = addWindow(
            CGRect(x: 300, y: 300, width: 700, height: 500), to: gateway)
        controller.handle(slot: .topLeft)
        let freshID = try XCTUnwrap(controller.registeredID(for: fresh))
        XCTAssertEqual(
            controller.canvas(for: replacementKey).state.occupant(of: .topLeft),
            freshID, "the replacement tiles on its own canvas")
        XCTAssertEqual(
            controller.canvas(for: oldKey).state.occupant(of: .topLeft), oldID,
            "the old canvas is untouched by the replacement's request")
    }

    /// A display whose Space id is withheld keys `(screen, nil)`. A
    /// renumber keeps that one canvas; while the Space is unknown the
    /// fallback still writes (A7's unknown-is-visible rule), and once the
    /// renumbered display names a Space the old fallback defers.
    func testWithheldCanvasOfARenumberedDisplayWritesWhileUnknownThenDefers() throws {
        var current = [Self.left]
        let gateway = FakeWindowGateway()
        // No Space ids are named, so the canvas is (screen, nil).
        let controller = makeController(gateway: gateway, screens: { current })
        let withheld = TilingSpaceKey(screen: Self.left.id, space: nil)

        let window = addWindow(
            CGRect(x: 100, y: 100, width: 800, height: 600), to: gateway)
        controller.handle(slot: .topLeft)
        let id = try XCTUnwrap(controller.registeredID(for: window))
        XCTAssertEqual(controller.focusedTilingSpace, withheld)

        current = [Self.renumberedLeft]
        screenChange()
        let renumberedWithheld = TilingSpaceKey(
            screen: Self.renumberedLeft.id, space: nil)
        XCTAssertEqual(
            controller.canvas(for: renumberedWithheld).state.occupant(of: .topLeft),
            id, "the renumbered display's withheld canvas is the same canvas")

        // Still unknown: the withheld fallback is the visible canvas.
        gateway.focused = window
        let performed = controller.handle(slot: .topRight)
        XCTAssertTrue(performed.performed)
        XCTAssertNil(performed.announcement)
        XCTAssertEqual(
            gateway.frame(of: window),
            GridLayout().rect(for: .topRight, in: Self.left.visibleFrame))

        // The renumbered display now names a Space: the old withheld
        // canvas is the stale fallback, so writes to it defer (A7).
        gateway.activeSpaces = [Self.renumberedLeftDisplayID: Self.spaceB]
        gateway.focused = window
        let deferred = controller.handle(slot: .topLeft)
        XCTAssertTrue(deferred.performed, "a deferral is never a failure")
        XCTAssertEqual(
            deferred.announcement,
            "That Space isn't visible yet: the change will apply when you return to it.")
        XCTAssertEqual(
            controller.canvas(for: renumberedWithheld).state.slot(of: id), .topLeft,
            "the deferred placement stands on the withheld canvas")
        XCTAssertTrue(
            controller.isMarkedStale(renumberedWithheld),
            "the deferred write leaves the canvas marked stale for its reassert")
    }

    /// A canvas established with the OS withholding the Space id keys
    /// `(screen, nil)`. Once its display is unplugged that canvas is
    /// invisible: a hotkey must defer rather than lay the window out
    /// against the main display's frame, and replug must reassert it.
    func testHotkeyOnAWithheldCanvasOfAnUnpluggedDisplayDefersThenReassertsOnReplug() {
        var current = [Self.left, Self.right]
        let gateway = FakeWindowGateway()
        // No Space ids are named, so each display's canvas is its
        // per-display fallback: (screen, nil).
        let controller = makeController(gateway: gateway, screens: { current })
        let withheld = TilingSpaceKey(screen: Self.right.id, space: nil)

        let rightHandle = addWindow(
            CGRect(x: 2000, y: 100, width: 800, height: 600), to: gateway)
        controller.handle(slot: .topLeft)
        let tiledFrame = gateway.frame(of: rightHandle)!
        XCTAssertEqual(
            controller.canvas(for: withheld).state.occupant(of: .topLeft), rightHandle.id,
            "the window tiled onto the display's withheld canvas")

        // The right display goes away; its kept canvas must never be
        // written in the dark.
        current = [Self.left]
        screenChange()

        // A hotkey still resolves the window's own (now unplugged)
        // canvas, and that canvas is not visible.
        gateway.focused = rightHandle
        let receipt = controller.handle(slot: .topRight)

        XCTAssertEqual(
            gateway.frame(of: rightHandle), tiledFrame,
            "an unplugged display's withheld canvas is not written")
        XCTAssertTrue(receipt.performed, "a deferral is never a failure")
        XCTAssertEqual(
            receipt.announcement,
            "That Space isn't visible yet: the change will apply when you return to it.")
        XCTAssertEqual(
            controller.canvas(for: withheld).state.slot(of: rightHandle.id), .topRight,
            "the deferred placement stands on the kept canvas")
        XCTAssertTrue(
            controller.isMarkedStale(withheld),
            "the deferred write leaves the kept canvas marked stale for the reassert")

        // Replug: the kept canvas reasserts against the restored display.
        current = [Self.left, Self.right]
        screenChange()
        XCTAssertEqual(
            gateway.frame(of: rightHandle),
            GridLayout().rect(for: .topRight, in: Self.right.visibleFrame),
            "replug reasserts the kept canvas against the restored display")
        XCTAssertFalse(
            controller.isMarkedStale(withheld),
            "the replug reassert clears the stale mark")
    }

    /// With no displays at all the canvas is genuinely display-less
    /// (`TilingSpaceKey.displayless`): there is no hidden canvas to
    /// protect, so it stays visible and still writes.
    func testDisplaylessCanvasStaysVisible() {
        let gateway = FakeWindowGateway()
        let controller = makeController(gateway: gateway, screens: { [] })

        let handle = addWindow(
            CGRect(x: 100, y: 100, width: 800, height: 600), to: gateway)
        let original = gateway.frame(of: handle)!
        controller.handle(slot: .topLeft)

        XCTAssertEqual(
            controller.canvas(for: .displayless).state.occupant(of: .topLeft), handle.id,
            "the window tiles onto the display-less canvas")
        XCTAssertNotEqual(
            gateway.frame(of: handle), original,
            "the display-less canvas is visible and still writes")
    }
}
