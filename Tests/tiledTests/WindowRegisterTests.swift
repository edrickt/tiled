import CoreGraphics
import XCTest

@testable import tiled

/// The controller's identity register: one id per live handle, ownership
/// read from the canvas records, and one forget that clears the handle,
/// its death clock, and its pending convergence check together.
final class WindowRegisterTests: XCTestCase {
    private let canvasA = TilingSpaceKey(screen: ScreenID(rawValue: 1), space: nil)
    private let canvasB = TilingSpaceKey(screen: ScreenID(rawValue: 2), space: nil)

    /// The fake canvas records: only these make an id live.
    private var owners: [WindowID: TilingSpaceKey] = [:]
    private var released: [(id: WindowID, owner: TilingSpaceKey)] = []
    private var scheduled: [() -> Void] = []
    private var cancellations = 0
    private var register: WindowRegister!

    override func setUp() {
        super.setUp()
        owners = [:]
        released = []
        scheduled = []
        cancellations = 0
        register = WindowRegister(
            owner: { [weak self] in self?.owners[$0] },
            releaseForeignClaim: { [weak self] id, owner in
                self?.released.append((id, owner))
                self?.owners[id] = nil
            },
            schedule: { [weak self] fire in
                self?.scheduled.append(fire)
                return { self?.cancellations += 1 }
            })
    }

    /// Models the canvas half of a claim: the canvas attaches the id and
    /// its record is what makes the id live.
    @discardableResult
    private func claimAndAttach(
        _ handle: WindowHandle, on key: TilingSpaceKey
    ) -> WindowID {
        let id = register.claim(handle, on: key)
        owners[id] = key
        return id
    }

    func testClaimAllocatesOneIDAndReusesItOnTheSameCanvas() {
        let handle = WindowHandle(id: 7)

        let first = claimAndAttach(handle, on: canvasA)

        XCTAssertEqual(first, 1, "the first claim takes the first id")
        XCTAssertEqual(register.liveID(for: handle), first)
        XCTAssertEqual(
            register.claim(handle, on: canvasA), first,
            "a live id on the claiming canvas is reused")
    }

    func testClaimReleasesAForeignRecordAndIssuesAFreshID() {
        let handle = WindowHandle(id: 7)
        let old = claimAndAttach(handle, on: canvasB)

        let fresh = claimAndAttach(handle, on: canvasA)

        XCTAssertEqual(
            released.map(\.id), [old],
            "the old canvas releases the record before the new claim")
        XCTAssertEqual(released.first?.owner, canvasB)
        XCTAssertNil(owners[old], "the old record is gone")
        XCTAssertNotEqual(fresh, old, "a foreign claim issues a fresh id")
        XCTAssertEqual(owners[fresh], canvasA)
        XCTAssertEqual(register.liveID(for: handle), fresh)
    }

    func testLiveIDGoesNilWhenTheCanvasRecordIsGone() {
        let handle = WindowHandle(id: 7)
        let id = claimAndAttach(handle, on: canvasA)
        XCTAssertEqual(register.liveID(for: handle), id)

        owners[id] = nil

        XCTAssertNil(
            register.liveID(for: handle),
            "an id without a canvas record is not a live window")
        XCTAssertEqual(
            claimAndAttach(handle, on: canvasA), id + 1,
            "the next claim replaces the stale mapping with a fresh id")
    }

    func testForgetClearsTheHandleDeathClockAndVerificationWithoutReusingIDs() {
        let handle = WindowHandle(id: 7)
        let id = claimAndAttach(handle, on: canvasA)
        _ = register.deathClock(id, seenAt: 10)
        register.scheduleVerification(of: id) {}
        XCTAssertTrue(register.hasPendingDeath(id))
        XCTAssertEqual(scheduled.count, 1)

        owners[id] = nil // the canvas released its record with the window
        register.forget(id)

        XCTAssertNil(register.liveID(for: handle), "the handle entry is gone")
        XCTAssertFalse(register.hasPendingDeath(id), "the death clock is gone")
        XCTAssertEqual(cancellations, 1, "the pending check is cancelled")

        let next = claimAndAttach(handle, on: canvasA)
        XCTAssertEqual(next, id + 1, "forget must not rewind the allocator")
    }

    func testForgetLeavesOtherWindowsAlone() {
        let first = WindowHandle(id: 7)
        let second = WindowHandle(id: 8)
        let firstID = claimAndAttach(first, on: canvasA)
        let secondID = claimAndAttach(second, on: canvasA)
        register.scheduleVerification(of: firstID) {}
        register.scheduleVerification(of: secondID) {}

        owners[firstID] = nil
        register.forget(firstID)

        XCTAssertNil(register.liveID(for: first))
        XCTAssertEqual(register.liveID(for: second), secondID)
        XCTAssertEqual(scheduled.count, 2, "both checks were scheduled")
        XCTAssertEqual(
            cancellations, 1,
            "forget cancels its own check and leaves the other window's alone; "
                + "a stale second cancellation would make this two")
    }

    func testDeathConfirmationKeepsTheFirstSightingUntilCleared() {
        let id = claimAndAttach(WindowHandle(id: 7), on: canvasA)

        XCTAssertEqual(register.deathClock(id, seenAt: 10), 10)
        XCTAssertEqual(
            register.deathClock(id, seenAt: 12), 10,
            "a later dead sighting keeps the first clock")
        XCTAssertTrue(register.hasPendingDeath(id))

        register.clearDeath(id)
        XCTAssertFalse(register.hasPendingDeath(id))
        XCTAssertEqual(
            register.deathClock(id, seenAt: 14), 14,
            "a cleared clock starts a new confirmation window")

        register.clearDeath(id)
        register.retainDeaths(only: [])
        XCTAssertFalse(register.hasPendingDeath(id))
    }

    func testANewerVerificationCancelsTheOlderOne() {
        let id = claimAndAttach(WindowHandle(id: 7), on: canvasA)
        var fired = 0
        register.scheduleVerification(of: id) { fired += 1 }
        register.scheduleVerification(of: id) { fired += 1 }

        XCTAssertEqual(cancellations, 1, "the superseded check is cancelled")
        XCTAssertEqual(scheduled.count, 2)

        scheduled[1]()
        XCTAssertEqual(fired, 1, "only the latest check runs")
        register.cancelVerification(id)
        XCTAssertEqual(
            cancellations, 1,
            "a check that already ran holds no cancellation to call")
    }
}
