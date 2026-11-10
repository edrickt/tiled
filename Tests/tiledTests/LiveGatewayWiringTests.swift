import ApplicationServices
import CoreGraphics
import XCTest

@testable import tiled

/// The live adapter's wiring, exercised without an Accessibility grant:
/// the Space table and its cache, observer registration and routing, and
/// the frame write pair with its partial-write rollback. Fakes stand in
/// for the window server and AX, so no real observer, permission prompt,
/// or Space table is involved.
final class LiveGatewayWiringTests: XCTestCase {
    private func makeGateway(
        observerDriver: FakeAXObserverDriver = FakeAXObserverDriver(),
        spaceTable: @escaping () -> [CGDirectDisplayID: SpaceID] = { [:] },
        now: @escaping () -> Date = Date.init,
        writeRetrySleep: @escaping (TimeInterval) -> Void = { _ in },
        runningProcessIDs: @escaping () -> [pid_t] = { [] },
        ownProcessID: @escaping () -> pid_t = { 0 },
        windowList: @escaping (pid_t) -> [AXUIElement]? = { _ in nil }
    ) -> LiveWindowGateway {
        LiveWindowGateway(
            observerDriver: observerDriver,
            spaceTable: spaceTable,
            now: now,
            workspaceNotifications: NotificationCenter(),
            writeRetrySleep: writeRetrySleep,
            runningProcessIDs: runningProcessIDs,
            ownProcessID: ownProcessID,
            windowList: windowList,
            // Never arm a real session tap in the suite: it would consume
            // the test machine's clicks for the rest of the run.
            titleBarTapFactory: { _, _, _ in nil })
    }

    // MARK: Space lookup and cache

    func testSpaceLookupPopulatesTheCacheOnFirstUse() {
        let display: CGDirectDisplayID = 7
        let space = SpaceID(rawValue: 70)
        var reads = 0
        let gateway = makeGateway(spaceTable: {
            reads += 1
            return [display: space]
        })

        XCTAssertEqual(gateway.activeSpace(on: display), space)
        XCTAssertEqual(reads, 1, "the first lookup reads the window-server table")
    }

    func testRepeatedLookupInsideTheLifetimeUsesTheCachedTable() {
        let display: CGDirectDisplayID = 7
        var reads = 0
        var clock = Date(timeIntervalSince1970: 0)
        let gateway = makeGateway(
            spaceTable: {
                reads += 1
                return [display: SpaceID(rawValue: 70)]
            },
            now: { clock })

        _ = gateway.activeSpace(on: display)
        clock = clock.addingTimeInterval(0.05)
        XCTAssertEqual(gateway.activeSpace(on: display), SpaceID(rawValue: 70))
        XCTAssertEqual(reads, 1, "a menu build's repeated rows share one table read")
    }

    func testLookupAfterTheLifetimeReReadsTheTable() {
        let display: CGDirectDisplayID = 7
        var space = SpaceID(rawValue: 70)
        var reads = 0
        var clock = Date(timeIntervalSince1970: 0)
        let gateway = makeGateway(
            spaceTable: {
                reads += 1
                return [display: space]
            },
            now: { clock })

        _ = gateway.activeSpace(on: display)
        space = SpaceID(rawValue: 71)
        clock = clock.addingTimeInterval(0.11)
        XCTAssertEqual(
            gateway.activeSpace(on: display), SpaceID(rawValue: 71),
            "a Space the notification missed is re-read once the cache goes stale")
        XCTAssertEqual(reads, 2)
    }

    func testDisplayZeroReturnsNilWithoutReadingTheTable() {
        var reads = 0
        let gateway = makeGateway(spaceTable: {
            reads += 1
            return [0: SpaceID(rawValue: 99)]
        })

        XCTAssertNil(gateway.activeSpace(on: 0))
        XCTAssertEqual(reads, 0, "display 0 is not a display: never consult the table")
    }

    func testSpaceChangeInvalidatesTheCacheAndNotifiesTheCanvasLayer() {
        let display: CGDirectDisplayID = 7
        var space = SpaceID(rawValue: 70)
        var reads = 0
        let clock = Date(timeIntervalSince1970: 0)
        let gateway = makeGateway(
            spaceTable: {
                reads += 1
                return [display: space]
            },
            now: { clock })
        var notified = 0
        gateway.observeSpaceChanges { notified += 1 }
        _ = gateway.activeSpace(on: display)

        space = SpaceID(rawValue: 71)
        gateway.spaceDidChange()

        XCTAssertEqual(notified, 1, "the swipe reaches the canvas layer")
        XCTAssertEqual(
            gateway.activeSpace(on: display), SpaceID(rawValue: 71),
            "the notification invalidates the cache, so the next lookup re-reads")
        XCTAssertEqual(reads, 2)
    }

    // MARK: Focus memo

    func testFocusedWindowMemoizesInsideTheLifetimeAndReReadsAfter() {
        var clock = Date(timeIntervalSince1970: 0)
        let gateway = makeGateway(now: { clock })
        let handle = gateway.registerTestWindow(
            pid: 100, token: 1, frames: FakeWindowFrames(frame: nil))
        var reads = 0
        gateway.setTestFocusedWindow {
            reads += 1
            return handle
        }

        XCTAssertEqual(gateway.focusedWindow(), handle)
        XCTAssertEqual(gateway.focusedWindow(), handle)
        XCTAssertEqual(reads, 1, "a menu build's repeated asks share one focus read")

        clock = clock.addingTimeInterval(0.06)
        XCTAssertEqual(gateway.focusedWindow(), handle)
        XCTAssertEqual(reads, 2, "the lifetime only bounds a pass that races a notification")
    }

    func testReleasingTheFocusedHandleForcesAReRead() {
        let gateway = makeGateway()
        let handle = gateway.registerTestWindow(
            pid: 100, token: 1, frames: FakeWindowFrames(frame: nil))
        var focused: WindowHandle? = handle
        gateway.setTestFocusedWindow { focused }
        XCTAssertEqual(gateway.focusedWindow(), handle)

        focused = nil
        gateway.release(handle)

        XCTAssertNil(
            gateway.focusedWindow(),
            "a released handle is never the memoized answer")
    }

    func testReleasingAnotherHandleKeepsTheFocusedAnswer() {
        let gateway = makeGateway()
        let focused = gateway.registerTestWindow(
            pid: 100, token: 1, frames: FakeWindowFrames(frame: nil))
        let other = gateway.registerTestWindow(
            pid: 100, token: 2, frames: FakeWindowFrames(frame: nil))
        var reads = 0
        gateway.setTestFocusedWindow {
            reads += 1
            return focused
        }
        XCTAssertEqual(gateway.focusedWindow(), focused)

        gateway.release(other)

        XCTAssertEqual(gateway.focusedWindow(), focused)
        XCTAssertEqual(reads, 1, "another window's release must not force an AX read")
    }

    // MARK: Observer registration

    func testFirstObserveCreatesOneObserverAndRegistersAllThreeNotifications() {
        let driver = FakeAXObserverDriver()
        let gateway = makeGateway(observerDriver: driver)
        let handle = gateway.registerTestWindow(
            pid: 100, token: 42,
            frames: FakeWindowFrames(
                frame: CGRect(x: 0, y: 0, width: 200, height: 100)))

        gateway.observe(handle, onChange: {}, onDestroyed: {})

        XCTAssertEqual(driver.observers.count, 1, "one observer per pid")
        XCTAssertEqual(driver.observers.first?.pid, 100)
        XCTAssertEqual(
            driver.observers.first?.notifications.sorted(),
            [
                kAXWindowResizedNotification, kAXWindowMovedNotification,
                kAXUIElementDestroyedNotification,
            ].map { $0 as String }.sorted(),
            "resize, move, and destroy all arrive through the one observer")
        XCTAssertTrue(
            driver.observers.first?.runLoopSourceAdded == true,
            "the observer's source is on the main runloop")
    }

    func testSecondHandleOnTheSamePIDReusesTheObserver() {
        let driver = FakeAXObserverDriver()
        let gateway = makeGateway(observerDriver: driver)
        let a = gateway.registerTestWindow(
            pid: 100, token: 1, frames: FakeWindowFrames(frame: nil))
        let b = gateway.registerTestWindow(
            pid: 100, token: 2, frames: FakeWindowFrames(frame: nil))

        gateway.observe(a, onChange: {}, onDestroyed: {})
        gateway.observe(b, onChange: {}, onDestroyed: {})

        XCTAssertEqual(
            driver.observers.count, 1,
            "one pid keeps one observer across its windows")
        XCTAssertEqual(
            driver.observers.first?.notifications.count, 6,
            "the second window registers its own three notifications")
    }

    func testFailedObserverCreationLeavesTheWindowRetryable() {
        let driver = FakeAXObserverDriver()
        let gateway = makeGateway(observerDriver: driver)
        let a = gateway.registerTestWindow(
            pid: 100, token: 1, frames: FakeWindowFrames(frame: nil))
        driver.createError = .cannotComplete

        gateway.observe(a, onChange: {}, onDestroyed: {})
        XCTAssertTrue(driver.observers.isEmpty)

        driver.createError = nil
        gateway.observe(a, onChange: {}, onDestroyed: {})
        XCTAssertEqual(driver.observers.count, 1)
        XCTAssertEqual(driver.observers.first?.notifications.count, 3)
    }

    func testFailedNotificationRegistrationLeavesTheWindowRetryable() {
        let driver = FakeAXObserverDriver()
        let gateway = makeGateway(observerDriver: driver)
        let a = gateway.registerTestWindow(
            pid: 100, token: 1, frames: FakeWindowFrames(frame: nil))
        driver.addFailures[kAXWindowResizedNotification as String] = .cannotComplete

        gateway.observe(a, onChange: {}, onDestroyed: {})
        XCTAssertEqual(driver.observers.first?.notifications.count, 2)

        driver.addFailures = [:]
        gateway.observe(a, onChange: {}, onDestroyed: {})
        XCTAssertEqual(
            driver.observers.first?.notifications.count, 5,
            "the retry re-adds all three, not just the failed one")
        XCTAssertEqual(driver.observers.count, 1, "the existing observer is reused")
    }

    func testDeliveredChangeNotificationCallsTheChangeHandler() {
        let driver = FakeAXObserverDriver()
        let gateway = makeGateway(observerDriver: driver)
        let a = gateway.registerTestWindow(
            pid: 100, token: 42, frames: FakeWindowFrames(frame: nil))
        var changes = 0
        var destroys = 0
        gateway.observe(
            a, onChange: { changes += 1 }, onDestroyed: { destroys += 1 })

        driver.deliver(kAXWindowResizedNotification as String, token: 42)
        driver.deliver(kAXWindowMovedNotification as String, token: 42)

        XCTAssertEqual(changes, 2)
        XCTAssertEqual(destroys, 0)
    }

    func testCreationPidResolvesTheDeliveredElementsOwner() {
        // The regression: a creation notification arrives with the
        // newborn window's element, never the subscribed app element, so
        // the app element's hash cannot route it. The owner is read off
        // the delivered element itself, with no Accessibility grant: the
        // pid travels with the proxy, nothing is read from the app.
        let me = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(
            LiveAXObserverDriver.creationPid(
                from: AXUIElementCreateApplication(me)),
            me,
            "the delivered element must name its owning pid")
        XCTAssertEqual(
            LiveAXObserverDriver.creationPid(from: AXUIElementCreateApplication(1)),
            1,
            "resolution reads the proxy, never the app")
    }

    func testCreationNotificationWithExplicitPidIgnoresTheTokenMap() {
        // A known pid from the delivered element wins over whatever the
        // token map says: an unlistable pid draws no birth instead of
        // routing somewhere stale.
        let gateway = makeGateway()
        var births = 0
        gateway.observeWindowCreations { _, _ in births += 1 }

        gateway.handleAXNotification(
            notification: kAXWindowCreatedNotification as String, token: 12345, pid: 999999)

        XCTAssertEqual(births, 0, "an unlistable pid draws no birth")
    }

    func testCreationNotificationWithoutPidOrMapEntryMissesSilently() {
        // Neither an owner nor a mapped token: the creation is
        // unroutable and must miss without crashing, exactly as before.
        let gateway = makeGateway()
        var births = 0
        gateway.observeWindowCreations { _, _ in births += 1 }

        gateway.handleAXNotification(
            notification: kAXWindowCreatedNotification as String, token: 12345)

        XCTAssertEqual(births, 0, "an unroutable creation draws no birth")
    }

    // MARK: Birth subscription

    func testBirthSubscriptionSkipsTheAppsOwnProcess() {
        // The audited bug: the running-app list contains Tiled itself, so
        // its own Settings/Welcome window was subscribed as a birth and
        // resized to the quarter footprint. The skip is subscribe-time.
        let driver = FakeAXObserverDriver()
        let ownPID: pid_t = 4242
        let otherPID: pid_t = 777
        let gateway = makeGateway(
            observerDriver: driver,
            runningProcessIDs: { [ownPID, otherPID] },
            ownProcessID: { ownPID })
        var births = 0
        gateway.observeWindowCreations { _, _ in births += 1 }

        XCTAssertEqual(
            driver.observers.map(\.pid), [otherPID],
            "only the other app's births are subscribed: Tiled's own pid never is")
    }

    func testLaunchSubscriptionSkipsTheAppsOwnProcess() {
        // The launch observer funnels through the same guard: a launch
        // report for the app itself can never subscribe its births.
        let driver = FakeAXObserverDriver()
        let ownPID: pid_t = 4242
        let otherPID: pid_t = 777
        let gateway = makeGateway(
            observerDriver: driver,
            runningProcessIDs: { [] },
            ownProcessID: { ownPID })
        var births = 0
        gateway.observeWindowCreations { _, _ in births += 1 }

        gateway.appLaunched(pid: ownPID)
        gateway.appLaunched(pid: otherPID)

        XCTAssertEqual(
            driver.observers.map(\.pid), [otherPID],
            "the launch path rejects the app's own pid too")
    }

    func testSelfPidCreationNotificationNeverDrawsABirth() {
        // The gateway wiring the controller sees: even a creation
        // delivered for the own pid (which no subscription can produce)
        // routes no handle to `handleWindowCreated`.
        let driver = FakeAXObserverDriver()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let gateway = makeGateway(
            observerDriver: driver,
            runningProcessIDs: { [ownPID] },
            ownProcessID: { ownPID })
        var births: [WindowHandle] = []
        gateway.observeWindowCreations { handle, _ in births.append(handle) }

        gateway.handleAXNotification(
            notification: kAXWindowCreatedNotification as String,
            token: 12345, pid: ownPID)

        XCTAssertTrue(births.isEmpty, "a self-pid creation is never a birth")
        XCTAssertTrue(
            driver.observers.isEmpty,
            "nothing subscribed the own pid, so no observer can deliver one")
    }

    func testManagedBirthNeedsAnObservedTokenOrIdentity() {
        // The rule behind focus-transparent births: only observed
        // bindings shadow a newborn. A focus-only token or element alone
        // never does, so a window adopted by a focus read still routes.
        let me = ProcessInfo.processInfo.processIdentifier
        let mine = AXUIElementCreateApplication(me)
        let mineAgain = AXUIElementCreateApplication(me)
        let other = AXUIElementCreateApplication(1)
        let myToken = UInt(CFHash(mine))
        XCTAssertTrue(
            LiveWindowGateway.isManagedBirth(
                token: myToken, element: mineAgain,
                observedTokens: [myToken], observedElements: []),
            "an observed token shadows even a reissued element")
        XCTAssertTrue(
            LiveWindowGateway.isManagedBirth(
                token: 12345, element: mineAgain,
                observedTokens: [], observedElements: [mine]),
            "identity with an observed window shadows without the token")
        XCTAssertFalse(
            LiveWindowGateway.isManagedBirth(
                token: UInt(CFHash(other)), element: other,
                observedTokens: [myToken], observedElements: [mine]),
            "a focus-only stranger routes: nothing observed matches it")
        XCTAssertFalse(
            LiveWindowGateway.isManagedBirth(
                token: myToken, element: mineAgain,
                observedTokens: [], observedElements: []),
            "a focus-only token alone never shadows")
    }

    func testChurnAdoptsStaleObservedWindowWithMatchingFrame() {
        // Terminal replaces its window element on every tab switch while
        // still reporting one window: the newborn shares the tile's
        // frame, and the held element is gone from the fresh list.
        let me = ProcessInfo.processInfo.processIdentifier
        let held = AXUIElementCreateApplication(me)
        let stranger = AXUIElementCreateApplication(1)
        let frame = CGRect(x: 0, y: 4, width: 839, height: 1015)
        let handle = WindowHandle(id: 7)
        let binding = LiveWindowGateway.WindowBinding(
            element: held, pid: me,
            frames: FakeWindowFrames(frame: frame), token: 42,
            observedKey: 42, changeHandler: nil,
            destructionHandler: nil, lastFrame: frame)

        XCTAssertEqual(
            LiveWindowGateway.churnedHandle(
                frame: frame, listed: [stranger],
                candidates: [handle: binding]),
            handle,
            "the same window under a new identity adopts, never births")
    }

    func testChurnIgnoresObservedWindowTheAppStillLists() {
        // A Firefox tab tear-off shares the source frame mid-drag, but
        // the source window is still listed: that birth still parks for
        // the drop instead of adopting the source's handle.
        let me = ProcessInfo.processInfo.processIdentifier
        let held = AXUIElementCreateApplication(me)
        let heldAgain = AXUIElementCreateApplication(me)
        let frame = CGRect(x: 0, y: 4, width: 839, height: 1015)
        let handle = WindowHandle(id: 7)
        let binding = LiveWindowGateway.WindowBinding(
            element: held, pid: me,
            frames: FakeWindowFrames(frame: frame), token: 42,
            observedKey: 42, changeHandler: nil,
            destructionHandler: nil, lastFrame: frame)

        XCTAssertNil(
            LiveWindowGateway.churnedHandle(
                frame: frame, listed: [heldAgain],
                candidates: [handle: binding]),
            "a live window the app still lists never adopts")
    }

    func testChurnIgnoresDistantFrame() {
        // A closed window replaced by a cascaded newcomer keeps the
        // count flat, but the frame moved: that birth still sizes.
        let me = ProcessInfo.processInfo.processIdentifier
        let held = AXUIElementCreateApplication(me)
        let stranger = AXUIElementCreateApplication(1)
        let oldFrame = CGRect(x: 840, y: 0, width: 840, height: 1019)
        let handle = WindowHandle(id: 7)
        let binding = LiveWindowGateway.WindowBinding(
            element: held, pid: me,
            frames: FakeWindowFrames(frame: oldFrame), token: 42,
            observedKey: 42, changeHandler: nil,
            destructionHandler: nil, lastFrame: oldFrame)

        XCTAssertNil(
            LiveWindowGateway.churnedHandle(
                frame: CGRect(x: 10, y: 10, width: 800, height: 600),
                listed: [stranger], candidates: [handle: binding]),
            "a frame that moved is a new window, not churn")
    }

    func testChurnNeedsALastFrame() {
        // No baseline read yet: membership is undeterminable, never an
        // adoption.
        let me = ProcessInfo.processInfo.processIdentifier
        let held = AXUIElementCreateApplication(me)
        let stranger = AXUIElementCreateApplication(1)
        let frame = CGRect(x: 0, y: 4, width: 839, height: 1015)
        let handle = WindowHandle(id: 7)
        let binding = LiveWindowGateway.WindowBinding(
            element: held, pid: me,
            frames: FakeWindowFrames(frame: frame), token: 42,
            observedKey: 42, changeHandler: nil,
            destructionHandler: nil, lastFrame: nil)

        XCTAssertNil(
            LiveWindowGateway.churnedHandle(
                frame: frame, listed: [stranger],
                candidates: [handle: binding]),
            "without a baseline the match is a maybe, never an adopt")
    }

    func testChurnNeedsAHeldElement() {
        // A test binding with no AX element carries no identity to prove
        // stale: it never adopts.
        let me = ProcessInfo.processInfo.processIdentifier
        let stranger = AXUIElementCreateApplication(1)
        let frame = CGRect(x: 0, y: 4, width: 839, height: 1015)
        let handle = WindowHandle(id: 7)
        let binding = LiveWindowGateway.WindowBinding(
            element: nil, pid: me,
            frames: FakeWindowFrames(frame: frame), token: 42,
            observedKey: 42, changeHandler: nil,
            destructionHandler: nil, lastFrame: frame)

        XCTAssertNil(
            LiveWindowGateway.churnedHandle(
                frame: frame, listed: [stranger],
                candidates: [handle: binding]),
            "without a held element staleness cannot be shown")
    }

    func testChurnPicksClosestFrameBreakingTiesByHandleID() {
        // Two stale observed windows of one pid both within tolerance:
        // the adoption must be deterministic — closest frame wins, ties
        // go to the smallest handle id — never Dictionary order.
        let me = ProcessInfo.processInfo.processIdentifier
        let stranger = AXUIElementCreateApplication(1)
        let frame = CGRect(x: 0, y: 4, width: 839, height: 1015)
        let drifted = CGRect(x: 0.9, y: 4, width: 839, height: 1015)
        let driftedBinding = LiveWindowGateway.WindowBinding(
            element: AXUIElementCreateApplication(me), pid: me,
            frames: FakeWindowFrames(frame: drifted), token: 42,
            observedKey: 42, changeHandler: nil,
            destructionHandler: nil, lastFrame: drifted)
        let exactBinding = LiveWindowGateway.WindowBinding(
            element: AXUIElementCreateApplication(me), pid: me,
            frames: FakeWindowFrames(frame: frame), token: 43,
            observedKey: 43, changeHandler: nil,
            destructionHandler: nil, lastFrame: frame)
        XCTAssertEqual(
            LiveWindowGateway.churnedHandle(
                frame: frame, listed: [stranger],
                candidates: [
                    WindowHandle(id: 7): driftedBinding,
                    WindowHandle(id: 9): exactBinding,
                ]),
            WindowHandle(id: 9),
            "the closest frame wins, not the first iterated")
        XCTAssertEqual(
            LiveWindowGateway.churnedHandle(
                frame: frame, listed: [stranger],
                candidates: [
                    WindowHandle(id: 9): exactBinding,
                    WindowHandle(id: 7): exactBinding,
                ]),
            WindowHandle(id: 7),
            "exact ties break to the smallest handle id")
    }

    func testChurnAdoptsWithinTwoPoints() {
        // Rounding plus a one-point nudge (display change, Dock shift)
        // between the baseline and the newborn read is still the same
        // window: a 1.5-point drift adopts instead of quarter-sizing the
        // tile.
        let me = ProcessInfo.processInfo.processIdentifier
        let stranger = AXUIElementCreateApplication(1)
        let frame = CGRect(x: 0, y: 4, width: 839, height: 1015)
        let drifted = CGRect(x: 1.5, y: 4, width: 839, height: 1015)
        let handle = WindowHandle(id: 7)
        let binding = LiveWindowGateway.WindowBinding(
            element: AXUIElementCreateApplication(me), pid: me,
            frames: FakeWindowFrames(frame: drifted), token: 42,
            observedKey: 42, changeHandler: nil,
            destructionHandler: nil, lastFrame: drifted)

        XCTAssertEqual(
            LiveWindowGateway.churnedHandle(
                frame: frame, listed: [stranger],
                candidates: [handle: binding]),
            handle,
            "a jitter-scale drift is churn, not a birth")
    }

    // MARK: Churn pre-filter (the direct birth path's one ambiguity)

    func testChurnCandidateIsACloseFrameOfTheSameObservedPid() {
        // The direct birth path consults the app's fresh window list only
        // for a shape that could be a churned identity: a held observed
        // window of the same pid whose last-read frame is within the churn
        // tolerance. Everything else writes the quarter footprint at once.
        let me = ProcessInfo.processInfo.processIdentifier
        let frame = CGRect(x: 0, y: 4, width: 839, height: 1015)
        let handle = WindowHandle(id: 7)
        let binding = LiveWindowGateway.WindowBinding(
            element: AXUIElementCreateApplication(me), pid: me,
            frames: FakeWindowFrames(frame: frame), token: 42,
            observedKey: 42, changeHandler: nil,
            destructionHandler: nil, lastFrame: frame)
        let bindings = [handle: binding]

        XCTAssertTrue(
            LiveWindowGateway.hasChurnCandidate(
                frame: frame, pid: me, bindings: bindings),
            "a same-app window at the newborn's exact frame may be churn")
        XCTAssertTrue(
            LiveWindowGateway.hasChurnCandidate(
                frame: frame.offsetBy(dx: 1.5, dy: -1), pid: me,
                bindings: bindings),
            "jitter inside the churn tolerance is still a candidate")
        XCTAssertFalse(
            LiveWindowGateway.hasChurnCandidate(
                frame: frame.offsetBy(dx: 20, dy: 0), pid: me,
                bindings: bindings),
            "a frame the window moved to is a new window, not a candidate")
        XCTAssertFalse(
            LiveWindowGateway.hasChurnCandidate(
                frame: frame, pid: me + 1, bindings: bindings),
            "another app's window never candidates")
    }

    func testChurnCandidateNeedsAnObservedHeldFrame() {        // Focus-only bindings never shadow a birth, and a candidate with no
        // held element or no last-read frame cannot be the churned
        // identity, so none of them buys the list read.
        let me = ProcessInfo.processInfo.processIdentifier
        let frame = CGRect(x: 0, y: 4, width: 839, height: 1015)
        let handle = WindowHandle(id: 7)

        let focusOnly = LiveWindowGateway.WindowBinding(
            element: AXUIElementCreateApplication(me), pid: me,
            frames: FakeWindowFrames(frame: frame), token: 42,
            observedKey: nil, changeHandler: nil,
            destructionHandler: nil, lastFrame: frame)
        XCTAssertFalse(
            LiveWindowGateway.hasChurnCandidate(
                frame: frame, pid: me, bindings: [handle: focusOnly]),
            "a focus-only binding is not a churn candidate")

        let noBaseline = LiveWindowGateway.WindowBinding(
            element: AXUIElementCreateApplication(me), pid: me,
            frames: FakeWindowFrames(frame: frame), token: 42,
            observedKey: 42, changeHandler: nil,
            destructionHandler: nil, lastFrame: nil)
        XCTAssertFalse(
            LiveWindowGateway.hasChurnCandidate(
                frame: frame, pid: me, bindings: [handle: noBaseline]),
            "without a last-read frame there is no candidate")

        let noElement = LiveWindowGateway.WindowBinding(
            element: nil, pid: me,
            frames: FakeWindowFrames(frame: frame), token: 42,
            observedKey: 42, changeHandler: nil,
            destructionHandler: nil, lastFrame: frame)
        XCTAssertFalse(
            LiveWindowGateway.hasChurnCandidate(
                frame: frame, pid: me, bindings: [handle: noElement]),
            "without a held element there is no identity to churn from")
    }

    // MARK: Direct birth route

    func testBirthRouteReportsAnAlreadyBoundElement() {
        // A focus read adopted the window before its creation notice, or an
        // earlier delivery won: the existing handle is reported, whatever
        // the frame says, and the controller's duplicate guard drops it.
        let existing = WindowHandle(id: 9)
        let frame = CGRect(x: 10, y: 10, width: 800, height: 600)

        XCTAssertEqual(
            LiveWindowGateway.birthRoute(
                frame: frame, existing: existing, managed: true, seen: false,
                churnCandidate: true),
            .existing(existing),
            "an already-bound element reports its handle before any other rule")
        XCTAssertEqual(
            LiveWindowGateway.birthRoute(
                frame: nil, existing: existing, managed: false, seen: false,
                churnCandidate: false),
            .existing(existing),
            "an unreadable frame cannot demote an already-bound element")
    }

    func testBirthRouteNeverBirthsAnObservedOrSeenWindow() {
        let frame = CGRect(x: 10, y: 10, width: 800, height: 600)

        XCTAssertEqual(
            LiveWindowGateway.birthRoute(
                frame: frame, existing: nil, managed: true, seen: false,
                churnCandidate: false),
            .alreadyKnown,
            "an observed token or identity is not a birth")
        XCTAssertEqual(
            LiveWindowGateway.birthRoute(
                frame: frame, existing: nil, managed: false, seen: true,
                churnCandidate: false),
            .alreadyKnown,
            "a token already seen is not a birth")
    }

    func testBirthRouteFallsBackOnlyForUnreadableOrChurnedDeliveries() {
        let frame = CGRect(x: 10, y: 10, width: 800, height: 600)

        XCTAssertEqual(
            LiveWindowGateway.birthRoute(
                frame: nil, existing: nil, managed: false, seen: false,
                churnCandidate: false),
            .unreadable,
            "an unreadable frame drops to the list diff, never to a write")
        XCTAssertEqual(
            LiveWindowGateway.birthRoute(
                frame: frame, existing: nil, managed: false, seen: false,
                churnCandidate: true),
            .confirmChurn,
            "a possible churned identity is confirmed before any write")
    }

    func testBirthRouteSizesEveryOtherNewborn() {
        XCTAssertEqual(
            LiveWindowGateway.birthRoute(
                frame: CGRect(x: 10, y: 10, width: 800, height: 600),
                existing: nil, managed: false, seen: false,
                churnCandidate: false),
            .birth,
            "a genuine newborn is written at once")
    }

    func testDeliveredDestroyedNotificationCallsTheDestroyHandler() {
        let driver = FakeAXObserverDriver()
        let gateway = makeGateway(observerDriver: driver)
        let a = gateway.registerTestWindow(
            pid: 100, token: 42, frames: FakeWindowFrames(frame: nil))
        var changes = 0
        var destroys = 0
        gateway.observe(
            a, onChange: { changes += 1 }, onDestroyed: { destroys += 1 })

        driver.deliver(kAXUIElementDestroyedNotification as String, token: 42)

        XCTAssertEqual(destroys, 1)
        XCTAssertEqual(changes, 0, "destroy is not a change: never read the frame")
    }

    func testAdoptionRetargetsRoutingAndFrames() {
        // A fresh AXUIElement reference for the same window has a new
        // CFHash. Adoption must move the observation key with it, or the
        // window's notifications fall through for the rest of the session.
        let driver = FakeAXObserverDriver()
        let gateway = makeGateway(observerDriver: driver)
        let oldFrames = FakeWindowFrames(
            frame: CGRect(x: 10, y: 20, width: 200, height: 100))
        let newFrames = FakeWindowFrames(
            frame: CGRect(x: 30, y: 40, width: 300, height: 150))
        let a = gateway.registerTestWindow(pid: 100, token: 42, frames: oldFrames)
        var changes = 0
        gateway.observe(a, onChange: { changes += 1 }, onDestroyed: {})

        gateway.adoptTestWindow(a, token: 99, frames: newFrames)

        driver.deliver(kAXWindowResizedNotification as String, token: 42)
        XCTAssertEqual(changes, 0, "the stale token no longer routes")
        driver.deliver(kAXWindowResizedNotification as String, token: 99)
        XCTAssertEqual(changes, 1, "the adopted token routes")
        XCTAssertEqual(gateway.frame(of: a), newFrames.frame())
        XCTAssertEqual(
            driver.observers.first?.notifications.count, 6,
            "the adopted identity re-registers on the shared observer")
    }

    func testReleaseDropsTheFrameAndHandlersAndPrunesTheLastObserver() {
        let driver = FakeAXObserverDriver()
        let gateway = makeGateway(observerDriver: driver)
        let frame = CGRect(x: 10, y: 20, width: 200, height: 100)
        let a = gateway.registerTestWindow(
            pid: 100, token: 1, frames: FakeWindowFrames(frame: frame))
        let b = gateway.registerTestWindow(
            pid: 100, token: 2, frames: FakeWindowFrames(frame: frame))
        var changes = 0
        gateway.observe(a, onChange: { changes += 1 }, onDestroyed: {})
        gateway.observe(b, onChange: { changes += 1 }, onDestroyed: {})

        gateway.release(a)

        XCTAssertNil(gateway.frame(of: a), "release drops the frame access")
        driver.deliver(kAXWindowResizedNotification as String, token: 1)
        XCTAssertEqual(changes, 0, "release drops the change handler")
        XCTAssertTrue(
            driver.removedRunLoopSources.isEmpty,
            "the shared observer stays while another window uses it")

        gateway.release(b)

        XCTAssertNil(gateway.frame(of: b))
        driver.deliver(kAXWindowResizedNotification as String, token: 2)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(
            driver.removedRunLoopSources.count, 1,
            "the pid's last handle prunes the observer and its runloop source")
    }

    func testReleaseForgetsTheObservationKeySoTheWindowCanRegisterAgain() {
        let driver = FakeAXObserverDriver()
        let gateway = makeGateway(observerDriver: driver)
        let a = gateway.registerTestWindow(
            pid: 100, token: 1, frames: FakeWindowFrames(frame: nil))
        let b = gateway.registerTestWindow(
            pid: 100, token: 2, frames: FakeWindowFrames(frame: nil))
        gateway.observe(a, onChange: {}, onDestroyed: {})
        gateway.observe(b, onChange: {}, onDestroyed: {})
        XCTAssertEqual(driver.observers.first?.notifications.count, 6)

        gateway.release(a)
        let c = gateway.registerTestWindow(
            pid: 100, token: 1, frames: FakeWindowFrames(frame: nil))
        var changes = 0
        gateway.observe(c, onChange: { changes += 1 }, onDestroyed: {})

        XCTAssertEqual(
            driver.observers.first?.notifications.count, 9,
            "the released element's key registered again on the shared observer")
        XCTAssertEqual(driver.observers.count, 1)
        driver.deliver(kAXWindowResizedNotification as String, token: 1)
        XCTAssertEqual(changes, 1)
    }

    func testReleaseDropsAnUnobservedBindingInOneRemoval() {
        // A scripted window can be registered and released without ever
        // being observed. Release must remove the whole binding, not
        // early-return for the missing observation key.
        let gateway = makeGateway()
        let frame = CGRect(x: 10, y: 20, width: 200, height: 100)
        let handle = gateway.registerTestWindow(
            pid: 100, token: 1, frames: FakeWindowFrames(frame: frame))
        XCTAssertEqual(gateway.frame(of: handle), frame)

        gateway.release(handle)

        XCTAssertNil(gateway.frame(of: handle), "the binding is gone")
        XCTAssertEqual(gateway.liveness(of: handle), .dead, "no element is left to probe")
    }

    func testAdoptingAScriptedWindowKeepsItsMissingElementExplicit() {
        // The test seam's handle has a frame source but no AX element;
        // adoption rewrites the token and frames without inventing an
        // element, so liveness still reports the honest .dead.
        let gateway = makeGateway()
        let updated = FakeWindowFrames(
            frame: CGRect(x: 30, y: 40, width: 300, height: 150))
        let handle = gateway.registerTestWindow(
            pid: 100, token: 1, frames: FakeWindowFrames(frame: nil))

        gateway.adoptTestWindow(handle, token: 2, frames: updated)

        XCTAssertEqual(gateway.frame(of: handle), updated.frame())
        XCTAssertEqual(gateway.liveness(of: handle), .dead)
    }

    func testAppTerminationDropsBindingsOpenedOnlyForFocusReads() {
        // A window the controller merely asked about (menu build, glyph)
        // has no record for the death pass to release; its binding must
        // not outlive the app.
        let gateway = makeGateway()
        let frames = FakeWindowFrames(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let handle = gateway.registerTestWindow(pid: 4242, token: 1, frames: frames)
        XCTAssertNotNil(gateway.frame(of: handle))

        gateway.appTerminated(pid: 4242)

        XCTAssertNil(
            gateway.frame(of: handle),
            "a focus-only binding does not outlive its app")
    }

    // MARK: Binding lifetime

    func testFocusReadReleasesAFocusOnlyBindingForAClosedWindow() {
        // A window that merely held focus, then closed while its app kept
        // running: the next focus read in that app proves it absent from
        // the app's window list and releases it, so `handle(for:)`'s
        // linear scan stays bounded by live windows instead of growing
        // with every window ever focused.
        let closed = AXUIElementCreateApplication(999_990)
        let live = AXUIElementCreateApplication(999_991)
        var clock = Date(timeIntervalSince1970: 0)
        let gateway = makeGateway(
            now: { clock },
            windowList: { _ in [live] })
        let frame = CGRect(x: 10, y: 20, width: 200, height: 100)
        let closedHandle = gateway.registerTestWindow(
            pid: 4242, token: 1, frames: FakeWindowFrames(frame: frame),
            element: closed)
        XCTAssertEqual(gateway.frame(of: closedHandle), frame)

        gateway.setTestFocusedAXWindow { (live, 4242) }
        clock = clock.addingTimeInterval(0.1)
        let focused = gateway.focusedWindow()

        XCTAssertNotNil(focused)
        XCTAssertNotEqual(focused, closedHandle)
        XCTAssertNil(
            gateway.frame(of: closedHandle),
            "the closed window's focus-only binding is released on the next focus read")
    }

    func testAppTerminationDropsAnObservedBindingForAnUntiledWindow() {
        // A window that was tiled, then untiled, keeps its observation
        // binding but has no record: when its app quits, the controller's
        // death pass has nothing to release, so `appTerminated` itself
        // must drop the whole pid table and its token index.
        let driver = FakeAXObserverDriver()
        let gateway = makeGateway(observerDriver: driver)
        let frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        let handle = gateway.registerTestWindow(
            pid: 4242, token: 7, frames: FakeWindowFrames(frame: frame))
        var changes = 0
        gateway.observe(handle, onChange: { changes += 1 }, onDestroyed: {})

        gateway.appTerminated(pid: 4242)

        XCTAssertNil(gateway.frame(of: handle), "the quit app's binding is gone")
        driver.deliver(kAXWindowResizedNotification as String, token: 7)
        XCTAssertEqual(changes, 0, "the quit app's stale token no longer routes")
        XCTAssertEqual(
            driver.removedRunLoopSources.count, 1,
            "the quit prunes the pid's observer once")

        gateway.appTerminated(pid: 4242)
        XCTAssertEqual(
            driver.removedRunLoopSources.count, 1,
            "a repeated termination report never prunes the same pid twice")
    }

    // MARK: Frame reads and the write pair

    /// The reported bug: a tiled window landed a full window-height below
    /// its slot, so the bottom row sat off the screen with only its title
    /// bar showing. The position write must use the AppKit top-left point,
    /// the counterpart of AX's top-left position, not the frame's
    /// bottom-left origin.
    func testSetFrameLandsTheExactRequestedFrame() {
        let gateway = makeGateway()
        let frames = FakeWindowFrames(
            frame: CGRect(x: 10, y: 20, width: 200, height: 100))
        let handle = gateway.registerTestWindow(
            pid: 100, token: 1, frames: frames)
        let target = CGRect(x: 0, y: 0, width: 720, height: 437)

        XCTAssertTrue(gateway.setFrame(handle, to: target))
        XCTAssertEqual(
            frames.frame(), target,
            "the window must land exactly in its slot, not a height lower")
    }

    func testPartialWriteRestoresTheTopLeftWhenTheSizeIsRefused() {
        let gateway = makeGateway()
        let original = CGRect(x: 10, y: 20, width: 200, height: 100)
        let frames = FakeWindowFrames(frame: original)
        frames.sizeResults = [.failure]
        let handle = gateway.registerTestWindow(
            pid: 100, token: 1, frames: frames)
        let target = CGRect(x: 50, y: 60, width: 300, height: 200)

        XCTAssertFalse(
            gateway.setFrame(handle, to: target),
            "a refused size means the placement did not land")

        XCTAssertEqual(
            frames.topLeftWrites,
            [
                CGPoint(x: target.minX, y: target.maxY),
                CGPoint(x: original.minX, y: original.maxY),
            ],
            "the landed position is rolled back after the refusal")
        XCTAssertEqual(
            frames.sizeWrites, [target.size],
            "a permanent refusal is not retried")
        XCTAssertEqual(
            frames.frame(), original,
            "the app's window is left at its old frame, not half-moved")
    }

    func testRefusedPositionNeverWritesTheSize() {
        // The mirror of the size-refusal case: sizing at the old origin
        // would half-apply the pair, leaving the window the wrong shape in
        // a place the state no longer believes in.
        let gateway = makeGateway()
        let original = CGRect(x: 10, y: 20, width: 200, height: 100)
        let frames = FakeWindowFrames(frame: original)
        frames.topLeftResults = [.failure]
        let handle = gateway.registerTestWindow(
            pid: 100, token: 1, frames: frames)

        XCTAssertFalse(
            gateway.setFrame(
                handle, to: CGRect(x: 50, y: 60, width: 300, height: 200)),
            "a refused position means the placement did not land")

        XCTAssertEqual(
            frames.sizeWrites, [],
            "a refused position must not resize the window in place")
        XCTAssertEqual(frames.frame(), original, "the window is left alone")
    }

    func testTransientSizeFailureRetriesTheWholePairThroughTheAdapter() {
        var slept: [TimeInterval] = []
        let gateway = makeGateway(writeRetrySleep: { slept.append($0) })
        let frames = FakeWindowFrames(
            frame: CGRect(x: 10, y: 20, width: 200, height: 100))
        frames.sizeResults = [.cannotComplete]
        let handle = gateway.registerTestWindow(
            pid: 100, token: 1, frames: frames)
        let target = CGRect(x: 50, y: 60, width: 300, height: 200)

        XCTAssertTrue(gateway.setFrame(handle, to: target))

        XCTAssertEqual(
            frames.topLeftWrites,
            [
                CGPoint(x: target.minX, y: target.maxY),
                CGPoint(x: target.minX, y: target.maxY),
            ],
            "the pair retries as a unit after a busy app")
        XCTAssertEqual(frames.sizeWrites, [target.size, target.size])
        XCTAssertEqual(slept, [0.1], "the adapter uses the AXWrite backoff")
        XCTAssertEqual(frames.frame(), target)
    }

    func testSilentIgnoreReportsSuccessButLeavesTheFrame() {
        let gateway = makeGateway()
        let original = CGRect(x: 10, y: 20, width: 200, height: 100)
        let frames = FakeWindowFrames(frame: original)
        frames.ignoresWrites = true
        let handle = gateway.registerTestWindow(
            pid: 100, token: 1, frames: frames)

        XCTAssertTrue(
            gateway.setFrame(
                handle, to: CGRect(x: 50, y: 60, width: 300, height: 200)),
            "the app claimed success, so the adapter reports success")
        XCTAssertEqual(
            gateway.frame(of: handle), original,
            "the live frame is still the old one: the caller sees the truth on its next read")
    }

    // MARK: Title-bar double-click

    /// The gesture consumes the second click and delivers the window after
    /// the tap callback returns: the expand writes frames on the main queue.
    func testTitleBarDoubleClickConsumesTheSecondClickAndDeliversTheWindow() {
        let gateway = makeGateway()
        let handle = WindowHandle(id: 41)
        let point = CGPoint(x: 10, y: 20)
        gateway.setTestTitleBarWindow { $0 == point ? handle : nil }
        let delivered = expectation(description: "expand delivered")
        var windows: [WindowHandle] = []
        gateway.observeTitleBarDoubleClicks {
            windows.append($0)
            delivered.fulfill()
        }

        XCTAssertTrue(
            gateway.handleTitleBarMouseEvent(.down(clickCount: 2, point: point)),
            "a second click on a title bar is Tiled's and never reaches the app")
        XCTAssertEqual(windows, [], "the expand runs after the tap returns")
        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(windows, [handle])
    }

    /// The consumed down takes its paired up with it: the app must never
    /// receive an unmatched release.
    func testTheConsumedDownPairsWithAConsumedUp() {
        let gateway = makeGateway()
        gateway.setTestTitleBarWindow { _ in WindowHandle(id: 7) }
        gateway.observeTitleBarDoubleClicks { _ in }

        XCTAssertTrue(gateway.handleTitleBarMouseEvent(.down(clickCount: 2, point: .zero)))
        XCTAssertTrue(gateway.handleTitleBarMouseEvent(.up), "the release is consumed too")
        XCTAssertFalse(gateway.handleTitleBarMouseEvent(.up), "an unrelated release passes")
    }

    /// Single clicks and the odd counts inside a multi-click run belong to
    /// the app: only a completed double-click is the gesture.
    func testSingleClicksAndOddCountsReachTheApp() {
        let gateway = makeGateway()
        gateway.setTestTitleBarWindow { _ in WindowHandle(id: 1) }
        var windows: [WindowHandle] = []
        gateway.observeTitleBarDoubleClicks { windows.append($0) }

        XCTAssertFalse(gateway.handleTitleBarMouseEvent(.down(clickCount: 1, point: .zero)))
        XCTAssertFalse(gateway.handleTitleBarMouseEvent(.down(clickCount: 3, point: .zero)))
        XCTAssertTrue(windows.isEmpty)
    }

    /// Two quick double-clicks make the second pair click counts 3 and 4:
    /// the completed (even) click is the gesture both times.
    func testASecondQuickDoubleClickIsTheGestureAgain() {
        let gateway = makeGateway()
        gateway.setTestTitleBarWindow { _ in WindowHandle(id: 9) }
        let delivered = expectation(description: "both toggles delivered")
        delivered.expectedFulfillmentCount = 2
        var windows: [WindowHandle] = []
        gateway.observeTitleBarDoubleClicks {
            windows.append($0)
            delivered.fulfill()
        }

        XCTAssertTrue(gateway.handleTitleBarMouseEvent(.down(clickCount: 2, point: .zero)))
        XCTAssertTrue(gateway.handleTitleBarMouseEvent(.down(clickCount: 4, point: .zero)))
        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(windows.count, 2, "each completed double-click toggles once")
    }

    /// A double-click whose point is content (or empty space) is not a
    /// title-bar hit, so the app keeps its own behavior.
    func testAContentDoubleClickReachesTheApp() {
        let gateway = makeGateway()
        gateway.setTestTitleBarWindow { _ in nil }
        var windows: [WindowHandle] = []
        gateway.observeTitleBarDoubleClicks { windows.append($0) }

        XCTAssertFalse(gateway.handleTitleBarMouseEvent(.down(clickCount: 2, point: .zero)))
        XCTAssertTrue(windows.isEmpty)
    }

    /// The hit-test predicate accepts only the window role: content reports
    /// a child role and must never be mistaken for the title bar.
    func testTitleBarRoleIsTheWindowRoleOnly() {
        XCTAssertTrue(LiveWindowGateway.isTitleBarRole("AXWindow" as CFString))
        XCTAssertFalse(LiveWindowGateway.isTitleBarRole("AXScrollArea" as CFString))
        XCTAssertFalse(LiveWindowGateway.isTitleBarRole("AXButton" as CFString))
        XCTAssertFalse(LiveWindowGateway.isTitleBarRole(nil))
    }
}
