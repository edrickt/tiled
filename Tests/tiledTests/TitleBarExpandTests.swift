import ApplicationServices
import CoreGraphics
import XCTest

@testable import tiled

/// The title-bar double-click gesture at the adapter seam: the tap is
/// actually installed (and retried after a pre-trust failure), the
/// `CGEvent` fields the callback reads map to consumption, the paired
/// release claim and its reset on a disabled tap, the pre-trust
/// subscription gate, and the gesture's canvas resolution and
/// one-full-size rule through the controller.
///
/// The decision-level tap tests live in `LiveGatewayWiringTests`, the
/// controller toggle in `ExpandToggleTests`, and the canvas rule in
/// `TilingSpaceTests`; this suite pins the wiring those seams skip.
/// Nothing here arms a real session event tap: every injected factory
/// returns nil (or the callback is invoked directly with synthetic
/// events), so the suite can never consume the machine's clicks.
final class TitleBarExpandTests: XCTestCase {
    // MARK: - Injected geometry

    private static let displayID: CGDirectDisplayID = 42
    private static let otherDisplayID: CGDirectDisplayID = 43
    private static let spaceA = SpaceID(rawValue: 101)
    private static let spaceB = SpaceID(rawValue: 102)

    private static let display = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        name: "Display 1",
        displayID: displayID)

    private static let otherDisplay = ScreenInfo(
        id: ScreenID(rawValue: 2),
        frame: CGRect(x: 1600, y: 0, width: 1200, height: 1000),
        visibleFrame: CGRect(x: 1600, y: 0, width: 1200, height: 1000),
        name: "Display 2",
        displayID: otherDisplayID)

    private var harness: ControllerHarness!
    private var gateway: FakeWindowGateway { harness.gateway }
    private var controller: TilingController { harness.controller }

    override func setUp() {
        super.setUp()
        harness = ControllerHarness(
            screens: [Self.display], deathConfirmation: 3,
            isMouseDown: { true })
        controller.onChange = {}
    }

    /// A live adapter with every ambient dependency injected: a private
    /// notification centre (constructing it never subscribes to the
    /// running session) and a tap factory the test controls. The factory
    /// must never call `CGEvent.tapCreate`: an active session tap in the
    /// suite would consume the machine's own mouse clicks.
    private func makeLiveGateway(
        tapFactory: @escaping (
            CGEventTapCallBack, CGEventMask, UnsafeMutableRawPointer?
        ) -> CFMachPort?
    ) -> LiveWindowGateway {
        LiveWindowGateway(
            observerDriver: FakeAXObserverDriver(),
            spaceTable: { [:] },
            workspaceNotifications: NotificationCenter(),
            writeRetrySleep: { _ in },
            runningProcessIDs: { [] },
            ownProcessID: { 0 },
            windowList: { _ in nil },
            titleBarTapFactory: tapFactory)
    }

    /// The all-zero tap proxy: the callback never touches it.
    private var dummyProxy: CGEventTapProxy {
        unsafeBitCast(0, to: CGEventTapProxy.self)
    }

    private func mouseEvent(
        _ type: CGEventType, clicks: Int, at point: CGPoint = CGPoint(x: 40, y: 12)
    ) -> CGEvent {
        let event = CGEvent(
            mouseEventSource: nil, mouseType: type,
            mouseCursorPosition: point, mouseButton: .left)!
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        return event
    }

    /// Drives the captured tap callback and answers "did this event reach
    /// the app?" as a plain Bool. Never formats the `Unmanaged<CGEvent>`
    /// return into an assertion message: a failure would Mirror-print it,
    /// and Mirroring an `Unmanaged` traps.
    private func tapPasses(
        _ callback: CGEventTapCallBack,
        _ userInfo: UnsafeMutableRawPointer,
        _ type: CGEventType,
        _ event: CGEvent
    ) -> Bool {
        callback(dummyProxy, type, event, userInfo) != nil
    }

    // MARK: - The tap is installed, not just remembered

    /// The live adapter installs one active session event tap. The wiring
    /// helper passes a factory that only returns nil, so without this the
    /// suite would not notice if `observeTitleBarDoubleClicks` merely
    /// stored the handler and never asked for a tap.
    func testTheTitleBarTapIsActuallyInstalledOnSubscription() {
        var attempts = 0
        let adapter = makeLiveGateway(tapFactory: { _, _, _ in
            attempts += 1
            return nil
        })

        XCTAssertEqual(attempts, 0, "constructing the adapter must not arm a tap")
        adapter.observeTitleBarDoubleClicks { _ in }
        XCTAssertEqual(attempts, 1, "subscribing must attempt the session tap")
    }

    /// A tap that cannot install (pre-trust) leaves the system gesture
    /// alone; the subscription retries once Accessibility arrives. The
    /// retry is a second `observeTitleBarDoubleClicks` call from the
    /// permission flow, so the factory must be attempted again.
    func testAFailedTitleBarTapInstallIsRetriedOnTheAccessibilityGrant() {
        var attempts = 0
        let adapter = makeLiveGateway(tapFactory: { _, _, _ in
            attempts += 1
            return nil
        })

        adapter.observeTitleBarDoubleClicks { _ in }
        adapter.observeTitleBarDoubleClicks { _ in }
        XCTAssertEqual(
            attempts, 2,
            "a pre-trust install failure must be retried, not remembered as success")
    }

    /// The tap must observe the down *and* the paired up; a down-only mask
    /// would leave the app an unmatched release.
    func testTheTitleBarTapObservesTheLeftDownAndItsPairedUp() {
        var observed: CGEventMask?
        let adapter = makeLiveGateway(tapFactory: { _, mask, _ in
            observed = mask
            return nil
        })

        adapter.observeTitleBarDoubleClicks { _ in }

        let expected =
            (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        XCTAssertEqual(
            observed, expected,
            "the tap must observe exactly the left down and its paired up")
    }

    // MARK: - The callback reads the CGEvent (the decision-level seam skips this)

    /// The decision-level tap tests drive `handleTitleBarMouseEvent`
    /// directly, which never reads a `CGEvent`. The real callback must read the click count
    /// from `.mouseEventClickState` and the point from `event.location`,
    /// consume the completed double-click, and consume its release. A
    /// wrong field would make the gesture silently dead while every
    /// decision-level test still passed.
    func testTheTapCallbackConsumesTheCompletedDoubleClickAndItsRelease() {
        var callback: CGEventTapCallBack?
        var userInfo: UnsafeMutableRawPointer?
        let adapter = makeLiveGateway(tapFactory: { tap, _, info in
            callback = tap
            userInfo = info
            return nil
        })
        adapter.setTestTitleBarWindow { point in
            point == CGPoint(x: 40, y: 12) ? WindowHandle(id: 77) : nil
        }
        let delivered = expectation(description: "both completed double-clicks delivered")
        delivered.expectedFulfillmentCount = 2
        var clicked: [WindowHandle] = []
        adapter.observeTitleBarDoubleClicks {
            clicked.append($0)
            delivered.fulfill()
        }
        guard let callback, let userInfo else {
            return XCTFail("subscribing must hand the tap a callback and its back-reference")
        }

        XCTAssertTrue(
            tapPasses(
                callback, userInfo, .leftMouseDown,
                mouseEvent(.leftMouseDown, clicks: 1)),
            "the first click is the app's")
        XCTAssertFalse(
            tapPasses(
                callback, userInfo, .leftMouseDown,
                mouseEvent(.leftMouseDown, clicks: 2)),
            "the completed second click is Tiled's")
        XCTAssertFalse(
            tapPasses(
                callback, userInfo, .leftMouseUp,
                mouseEvent(.leftMouseUp, clicks: 2)),
            "its release is consumed with it")
        XCTAssertTrue(
            tapPasses(
                callback, userInfo, .leftMouseUp,
                mouseEvent(.leftMouseUp, clicks: 0)),
            "an unrelated release passes")
        XCTAssertTrue(
            tapPasses(
                callback, userInfo, .leftMouseDown,
                mouseEvent(.leftMouseDown, clicks: 3)),
            "the odd opening click of a second rapid run passes")
        XCTAssertFalse(
            tapPasses(
                callback, userInfo, .leftMouseDown,
                mouseEvent(.leftMouseDown, clicks: 4)),
            "the completed second double-click is the gesture again")
        XCTAssertFalse(
            tapPasses(
                callback, userInfo, .leftMouseUp,
                mouseEvent(.leftMouseUp, clicks: 4)))

        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(clicked, [WindowHandle(id: 77), WindowHandle(id: 77)])
    }

    /// A double-click whose point is content must not even arm the paired-
    /// release claim: the callback consumes nothing and the following
    /// release passes through.
    func testAContentHitDoesNotConsumeAndDoesNotArmTheRelease() {
        var callback: CGEventTapCallBack?
        var userInfo: UnsafeMutableRawPointer?
        let adapter = makeLiveGateway(tapFactory: { tap, _, info in
            callback = tap
            userInfo = info
            return nil
        })
        adapter.setTestTitleBarWindow { _ in nil }
        adapter.observeTitleBarDoubleClicks { _ in }
        guard let callback, let userInfo else {
            return XCTFail("subscribing must hand the tap a callback")
        }

        XCTAssertTrue(
            tapPasses(
                callback, userInfo, .leftMouseDown,
                mouseEvent(.leftMouseDown, clicks: 2)),
            "a content double-click reaches the app")
        XCTAssertTrue(
            tapPasses(
                callback, userInfo, .leftMouseUp,
                mouseEvent(.leftMouseUp, clicks: 2)),
            "and its release passes too: nothing was swallowed to pair with")
    }

    /// "A disabled tap also drops the unmatched-release claim": after the
    /// system disables the tap, the next release must reach the app rather
    /// than be swallowed by a stale claim.
    func testATapDisabledNotificationDropsThePairedReleaseClaim() {
        var callback: CGEventTapCallBack?
        var userInfo: UnsafeMutableRawPointer?
        let adapter = makeLiveGateway(tapFactory: { tap, _, info in
            callback = tap
            userInfo = info
            return nil
        })
        adapter.setTestTitleBarWindow { _ in WindowHandle(id: 5) }
        adapter.observeTitleBarDoubleClicks { _ in }
        guard let callback, let userInfo else {
            return XCTFail("subscribing must hand the tap a callback")
        }

        XCTAssertFalse(
            tapPasses(
                callback, userInfo, .leftMouseDown,
                mouseEvent(.leftMouseDown, clicks: 2)),
            "the completed double-click is consumed and arms the paired release")
        _ = callback(
            dummyProxy, .tapDisabledByTimeout,
            mouseEvent(.leftMouseUp, clicks: 0), userInfo)
        XCTAssertTrue(
            tapPasses(
                callback, userInfo, .leftMouseUp,
                mouseEvent(.leftMouseUp, clicks: 2)),
            "the disabled tap dropped the claim, so this release is the app's")
    }

    // MARK: - Controller wiring: trust gate and target resolution

    /// The gesture is subscribed at init only when AX is already trusted,
    /// and the permission flow's retry does the subscription once trust
    /// arrives. A controller that subscribed pre-trust would ask the live
    /// adapter for a tap it cannot create; one that never retried would
    /// leave the gesture dead until relaunch.
    func testTheGestureSubscriptionWaitsForTrustAndTheRetrySubscribesIt() {
        let untrusted = FakeWindowGateway()
        untrusted.isTrusted = false
        let preTrust = ControllerHarness(
            screens: [Self.display], gateway: untrusted,
            deathConfirmation: 3, isMouseDown: { true })

        XCTAssertEqual(
            untrusted.titleBarDoubleClickSubscriptions, 0,
            "pre-trust, the controller must not subscribe the tap it cannot install")

        untrusted.isTrusted = true
        preTrust.controller.observeTitleBarDoubleClicks()
        XCTAssertEqual(
            untrusted.titleBarDoubleClickSubscriptions, 1,
            "the Accessibility grant must subscribe the gesture")
    }

    /// A trusted controller subscribes exactly once at init: a duplicate
    /// subscription would deliver every gesture twice.
    func testATrustedControllerSubscribesTheGestureExactlyOnce() {
        XCTAssertEqual(
            gateway.titleBarDoubleClickSubscriptions, 1,
            "the controller's init subscription is the one gesture handler")
    }

    /// The gesture resolves its window by the click, not by focus, and an
    /// unmanaged window is claimed by the canvas showing *its* frame: a
    /// window on the unfocused display must expand against that display's
    /// visible frame, not the focused canvas's.
    func testTheGestureExpandsAnUnmanagedWindowOnItsOwnDisplay() {
        harness.screens = [Self.display, Self.otherDisplay]
        gateway.activeSpaces = [
            Self.displayID: Self.spaceA,
            Self.otherDisplayID: Self.spaceA,
        ]
        let focused = harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        let focusedID = controller.registeredID(for: focused)!

        let farWindow = gateway.addWindow(
            frame: CGRect(x: 1700, y: 100, width: 700, height: 500))
        XCTAssertEqual(gateway.focused, focused, "the window under the pointer is not focused")

        gateway.simulateTitleBarDoubleClick(on: farWindow)

        XCTAssertEqual(
            gateway.frame(of: farWindow), Self.otherDisplay.visibleFrame,
            "the double-clicked window expands on its own display")
        let farID = controller.registeredID(for: farWindow)!
        let farCanvas = controller.canvas(
            for: TilingSpaceKey(
                screen: Self.otherDisplay.id, space: Self.spaceA))
        XCTAssertTrue(farCanvas.isExpanded(farID))
        let focusedCanvas = controller.canvas(
            for: TilingSpaceKey(
                screen: Self.display.id, space: Self.spaceA))
        XCTAssertFalse(focusedCanvas.isExpanded(focusedID))
        XCTAssertEqual(
            gateway.frame(of: focused),
            focusedCanvas.grid.rect(for: .topLeft, in: Self.display.visibleFrame),
            "the focused window keeps its tile")
    }

    /// The gesture is the same toggle: on a tiled expanded window it must
    /// retile into the slot it kept, not restore a floating frame and not
    /// leave the expansion behind.
    func testTheGestureCollapsesATiledExpandedWindowIntoItsSlot() {
        let handle = harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        let tile = gateway.frame(of: handle)!

        gateway.simulateTitleBarDoubleClick(on: handle)
        let id = controller.registeredID(for: handle)!
        XCTAssertEqual(gateway.frame(of: handle), Self.display.visibleFrame)
        XCTAssertTrue(harness.canvas.isExpanded(id))

        gateway.simulateTitleBarDoubleClick(on: handle)
        XCTAssertEqual(gateway.frame(of: handle), tile, "it returns to the tile it kept")
        XCTAssertEqual(harness.canvas.state.slot(of: id), .topLeft)
        XCTAssertFalse(harness.canvas.isExpanded(id))
    }

    // MARK: - One full-size window through the gesture

    /// The gesture path must apply the one-full-size rule too: expanding
    /// the clicked window returns the coverer to its tile, and a landed
    /// gesture stays silent on the late-receipt route.
    func testTheGestureReturnsTheCovererToItsTileAndStaysSilent() {
        let a = harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        let aTile = gateway.frame(of: a)!
        controller.handleExpandToggle()
        XCTAssertEqual(gateway.frame(of: a), Self.display.visibleFrame)

        let b = harness.addFocusedWindow()
        controller.handle(slot: .bottomRight)
        var receipts: [ActionReceipt] = []
        controller.onLateReceipt = { receipts.append($0) }

        gateway.simulateTitleBarDoubleClick(on: b)

        XCTAssertEqual(receipts.count, 1, "the gesture reports through the late-receipt route")
        XCTAssertTrue(receipts[0].performed)
        XCTAssertNil(receipts[0].announcement, "a landed expansion stays silent")
        let aID = controller.registeredID(for: a)!
        let bID = controller.registeredID(for: b)!
        XCTAssertEqual(gateway.frame(of: a), aTile, "the coverer returns to its tile")
        XCTAssertFalse(harness.canvas.isExpanded(aID))
        XCTAssertTrue(harness.canvas.isExpanded(bID))
        XCTAssertEqual(gateway.frame(of: b), Self.display.visibleFrame)
    }

    /// A refused return must refuse the gesture's expansion and speak the
    /// blocked sentence once, naming the window that would not move; the
    /// clicked window is rolled back to where it was.
    func testTheGestureBlockedByTheCovererSpeaksOnceAndRollsBack() {
        let a = gateway.addWindow(frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        gateway.focused = a
        controller.handleExpandToggle()
        XCTAssertEqual(gateway.frame(of: a), Self.display.visibleFrame)

        let b = gateway.addWindow(frame: CGRect(x: 950, y: 120, width: 700, height: 500))
        let bFrame = gateway.frame(of: b)!
        gateway.focused = b
        gateway.refuseNextWrites(a)
        var receipts: [ActionReceipt] = []
        controller.onLateReceipt = { receipts.append($0) }

        gateway.simulateTitleBarDoubleClick(on: b)

        XCTAssertEqual(receipts.count, 1, "a blocked gesture announces exactly once")
        XCTAssertFalse(receipts[0].performed)
        XCTAssertEqual(
            receipts[0].announcement,
            "TestApp couldn't return to its tile, so nothing was expanded.")
        XCTAssertEqual(gateway.frame(of: b), bFrame, "the clicked window is rolled back")
        let aID = controller.registeredID(for: a)!
        XCTAssertTrue(harness.canvas.isExpanded(aID), "the coverer keeps covering")
        XCTAssertEqual(gateway.frame(of: a), Self.display.visibleFrame)
        if let bID = controller.registeredID(for: b) {
            XCTAssertFalse(harness.canvas.isExpanded(bID))
        }
    }

    // MARK: - The canvas rule at its own seam (tiled coverer + undo)

    /// The canvas suite's refusal test uses an *untiled* coverer (the
    /// saved-frame return). The common case is a tiled coverer whose slot retile is
    /// refused; that path must block the expansion too, roll the new
    /// window back to its tile, and add no undo chapter.
    func testATiledCoverersRefusedRetileBlocksTheExpansionWithoutAnUndoChapter() {
        let canvas = TilingSpaceHarness()
        let a = canvas.addWindow()
        canvas.apply(slot: .topLeft, requester: a)
        _ = canvas.space.expandToggle(window: a, context: canvas.context())
        XCTAssertEqual(canvas.frame(of: a), canvas.bounds)

        let b = canvas.addWindow()
        canvas.apply(slot: .bottomRight, requester: b)
        let bTile = canvas.rect(.bottomRight)
        canvas.gateway.refuseNextWrites(canvas.handle(of: a)!)

        let outcome = canvas.space.expandToggle(window: b, context: canvas.context())

        XCTAssertEqual(
            outcome.result, .expandBlocked(windowName: "TestApp"),
            "the tiled coverer's refused retile blocks the new expansion")
        XCTAssertTrue(canvas.space.isExpanded(a), "the coverer stays expanded, truthfully")
        XCTAssertFalse(canvas.space.isExpanded(b))
        XCTAssertEqual(canvas.frame(of: a), canvas.bounds, "the coverer still covers the layout")
        XCTAssertEqual(canvas.frame(of: b), bTile, "the new window is rolled back to its tile")
        XCTAssertEqual(canvas.space.state.slot(of: a), .topLeft)
        XCTAssertEqual(canvas.space.state.slot(of: b), .bottomRight)
        XCTAssertTrue(
            canvas.space.undoStack.isEmpty,
            "expand/collapse never adds an undo chapter, not even a blocked one")
    }

    /// A retained expansion landing on the swipe back goes through the
    /// same land-then-return rule; when the coverer refuses, the landing
    /// window is rolled back and the reassert re-derives it into the slot
    /// it kept.
    func testADeferredExpansionRefusedAtLandingLeavesTheNewWindowInItsSlot() {
        let canvas = TilingSpaceHarness()
        let a = canvas.addWindow()
        canvas.apply(slot: .topLeft, requester: a)
        _ = canvas.space.expandToggle(window: a, context: canvas.context())
        let b = canvas.addWindow()
        canvas.apply(slot: .bottomRight, requester: b)
        canvas.canvasVisible = false
        XCTAssertEqual(
            canvas.space.expandToggle(window: b, context: canvas.context()).result,
            .deferred)

        canvas.canvasVisible = true
        canvas.gateway.refuseNextWrites(canvas.handle(of: a)!)
        canvas.space.reassert(.grid, context: canvas.context())

        XCTAssertTrue(canvas.space.isExpanded(a), "the coverer keeps covering")
        XCTAssertEqual(canvas.frame(of: a), canvas.bounds)
        XCTAssertFalse(canvas.space.isExpanded(b))
        XCTAssertEqual(
            canvas.frame(of: b), canvas.rect(.bottomRight),
            "the rolled-back window is re-derived into the slot it kept")
        XCTAssertNil(canvas.space.deferredRequests[b], "the refused expansion is dropped")
        XCTAssertNotNil(canvas.space.error, "the swipe back narrates the refusal")
    }

    /// A newer hidden expansion supersedes an older one *while a coverer
    /// stays expanded*: the superseded request never lands, the coverer is
    /// returned only by the newest request's landing, and exactly one
    /// window covers the canvas when the Space returns.
    func testANewHiddenExpansionSupersedesOlderOnesWhileTheCovererWaits() {
        let canvas = TilingSpaceHarness()
        let a = canvas.addWindow()
        canvas.apply(slot: .topLeft, requester: a)
        _ = canvas.space.expandToggle(window: a, context: canvas.context())
        let b = canvas.addWindow()
        canvas.apply(slot: .bottomRight, requester: b)
        let c = canvas.addWindow(frame: CGRect(x: 100, y: 100, width: 700, height: 500))
        let cFrame = canvas.frame(of: c)!

        canvas.canvasVisible = false
        XCTAssertEqual(
            canvas.space.expandToggle(window: b, context: canvas.context()).result,
            .deferred)
        XCTAssertEqual(
            canvas.space.expandToggle(window: c, context: canvas.context()).result,
            .deferred)
        XCTAssertNil(
            canvas.space.deferredRequests[b],
            "the older retained expansion is superseded at request time")
        XCTAssertTrue(
            canvas.space.isExpanded(a),
            "a hidden canvas moves nothing: the coverer returns only when the newest lands")

        canvas.canvasVisible = true
        canvas.space.reassert(.grid, context: canvas.context())

        XCTAssertTrue(canvas.space.isExpanded(c), "only the newest expansion lands")
        XCTAssertFalse(canvas.space.isExpanded(a))
        XCTAssertFalse(canvas.space.isExpanded(b))
        XCTAssertEqual(canvas.frame(of: a), canvas.rect(.topLeft), "the coverer returns to its tile")
        XCTAssertEqual(canvas.frame(of: b), canvas.rect(.bottomRight))
        XCTAssertEqual(canvas.frame(of: c), canvas.bounds)
        XCTAssertEqual(canvas.space.expanded.count, 1)
    }

    /// A coverer collapsed while off-Space and a newer expansion retained
    /// for another window both reconcile on the swipe back, in either
    /// dictionary order, to one tiled window and one coverer.
    func testACovererCollapseAndANewerExpansionReconcileToOneCoverer() {
        let canvas = TilingSpaceHarness()
        let a = canvas.addWindow()
        canvas.apply(slot: .topLeft, requester: a)
        _ = canvas.space.expandToggle(window: a, context: canvas.context())
        let b = canvas.addWindow()
        canvas.apply(slot: .bottomRight, requester: b)

        canvas.canvasVisible = false
        XCTAssertEqual(
            canvas.space.expandToggle(window: b, context: canvas.context()).result,
            .deferred)
        XCTAssertEqual(
            canvas.space.expandToggle(window: a, context: canvas.context()).result,
            .deferred,
            "the coverer's own collapse is retained off-Space")

        canvas.canvasVisible = true
        canvas.space.reassert(.grid, context: canvas.context())

        XCTAssertFalse(canvas.space.isExpanded(a), "the retained collapse lands")
        XCTAssertTrue(canvas.space.isExpanded(b), "the retained expansion lands")
        XCTAssertEqual(canvas.frame(of: a), canvas.rect(.topLeft))
        XCTAssertEqual(canvas.frame(of: b), canvas.bounds)
        XCTAssertEqual(canvas.space.expanded.count, 1)
        XCTAssertTrue(canvas.space.deferredRequests.isEmpty)
    }

    /// A blocked expansion is retryable: the rollback must leave the
    /// clicked window where it was, so the next toggle (once the coverer
    /// accepts the return) succeeds.
    func testABlockedGestureCanBeRetriedOnceTheCovererReturns() {
        let canvas = TilingSpaceHarness()
        let a = canvas.addWindow()
        canvas.apply(slot: .topLeft, requester: a)
        _ = canvas.space.expandToggle(window: a, context: canvas.context())
        let b = canvas.addWindow(frame: CGRect(x: 100, y: 100, width: 700, height: 500))
        let bFrame = canvas.frame(of: b)!

        canvas.gateway.refuseNextWrites(canvas.handle(of: a)!)
        XCTAssertEqual(
            canvas.space.expandToggle(window: b, context: canvas.context()).result,
            .expandBlocked(windowName: "TestApp"))
        XCTAssertEqual(canvas.frame(of: b), bFrame)

        let retried = canvas.space.expandToggle(window: b, context: canvas.context())

        XCTAssertEqual(retried.result, .placed)
        XCTAssertFalse(canvas.space.isExpanded(a), "the coverer returns on the retry")
        XCTAssertTrue(canvas.space.isExpanded(b))
        XCTAssertEqual(canvas.frame(of: a), canvas.rect(.topLeft))
        XCTAssertEqual(canvas.frame(of: b), canvas.bounds)
        XCTAssertEqual(canvas.space.expanded.count, 1)
    }

    /// A retained expansion whose landing write is refused changes
    /// nothing: the coverer keeps covering, no expansion is recorded, and
    /// the refused request is not parked again.
    func testARetainedExpansionWhoseLandingIsRefusedLeavesTheCovererAlone() {
        let canvas = TilingSpaceHarness()
        let a = canvas.addWindow()
        canvas.apply(slot: .topLeft, requester: a)
        _ = canvas.space.expandToggle(window: a, context: canvas.context())
        let b = canvas.addWindow(frame: CGRect(x: 100, y: 100, width: 700, height: 500))
        let bFrame = canvas.frame(of: b)!

        canvas.canvasVisible = false
        XCTAssertEqual(
            canvas.space.expandToggle(window: b, context: canvas.context()).result,
            .deferred)
        canvas.canvasVisible = true
        canvas.gateway.refuseNextWrites(canvas.handle(of: b)!)
        canvas.space.reassert(.grid, context: canvas.context())

        XCTAssertTrue(canvas.space.isExpanded(a), "the coverer never moved")
        XCTAssertFalse(canvas.space.isExpanded(b))
        XCTAssertEqual(canvas.frame(of: a), canvas.bounds)
        XCTAssertEqual(canvas.frame(of: b), bFrame)
        XCTAssertNil(canvas.space.deferredRequests[b], "a refused landing is not retained")
        XCTAssertNotNil(canvas.space.error)
    }

    /// The scope is the canvas (display *and* Space), not the display: an
    /// expansion on one Space must not return the other Space's coverer.
    /// The per-monitor suite only covers the display dimension.
    func testOneFullSizeRuleIsScopedToTheSpaceNotJustTheDisplay() {
        gateway.activeSpaces = [Self.displayID: Self.spaceA]
        let a = harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        controller.handleExpandToggle()
        let aID = controller.registeredID(for: a)!

        gateway.activeSpaces[Self.displayID] = Self.spaceB
        gateway.simulateSpaceChange()
        let b = harness.addFocusedWindow()
        controller.handle(slot: .topLeft)
        controller.handleExpandToggle()
        let bID = controller.registeredID(for: b)!

        let spaceACanvas = controller.canvas(
            for: TilingSpaceKey(screen: Self.display.id, space: Self.spaceA))
        let spaceBCanvas = controller.canvas(
            for: TilingSpaceKey(screen: Self.display.id, space: Self.spaceB))
        XCTAssertTrue(
            spaceACanvas.isExpanded(aID),
            "the other Space's coverer is not returned by this Space's expansion")
        XCTAssertTrue(spaceBCanvas.isExpanded(bID))
        XCTAssertEqual(gateway.frame(of: a), Self.display.visibleFrame)
        XCTAssertEqual(gateway.frame(of: b), Self.display.visibleFrame)

        gateway.activeSpaces[Self.displayID] = Self.spaceA
        gateway.simulateSpaceChange()
        XCTAssertTrue(
            controller.canvas(
                for: TilingSpaceKey(screen: Self.display.id, space: Self.spaceA)
            ).isExpanded(aID),
            "swiping back leaves the first Space's expansion in place")
    }

    /// Three expansions in a row keep the invariant: each new coverer
    /// returns the one before it, and exactly one window is expanded.
    func testSuccessiveExpansionsKeepExactlyOneWindowExpanded() {
        var ids: [WindowID] = []
        var handles: [WindowHandle] = []
        for _ in 0..<3 {
            let handle = harness.addFocusedWindow()
            controller.handle(slot: .topLeft)
            controller.handleExpandToggle()
            handles.append(handle)
            ids.append(controller.registeredID(for: handle)!)
        }

        XCTAssertEqual(
            harness.canvas.expanded.count, 1,
            "a canvas never holds two expanded windows")
        XCTAssertEqual(harness.canvas.expanded.keys.first, ids.last)
        XCTAssertEqual(gateway.frame(of: handles.last!), Self.display.visibleFrame)
    }
}
