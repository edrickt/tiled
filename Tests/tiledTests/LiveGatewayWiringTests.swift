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
        writeRetrySleep: @escaping (TimeInterval) -> Void = { _ in }
    ) -> LiveWindowGateway {
        LiveWindowGateway(
            observerDriver: observerDriver,
            spaceTable: spaceTable,
            now: now,
            workspaceNotifications: NotificationCenter(),
            writeRetrySleep: writeRetrySleep)
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

    // MARK: Frame reads and the write pair

    func testPartialWriteRestoresTheOriginWhenTheSizeIsRefused() {
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
            frames.originWrites, [target.origin, original.origin],
            "the landed position is rolled back after the refusal")
        XCTAssertEqual(
            frames.sizeWrites, [target.size],
            "a permanent refusal is not retried")
        XCTAssertEqual(
            frames.frame(), original,
            "the app's window is left at its old frame, not half-moved")
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
            frames.originWrites, [target.origin, target.origin],
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
}
