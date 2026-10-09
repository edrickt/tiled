import CoreGraphics
import XCTest

@testable import tiled

/// The verify delay's production wiring, which every other test replaces
/// with an injected scheduler: `WriteExpectations.scheduleCheckOnMain`
/// arms one main-queue work item per performed write, delivers its fire
/// one `checkDelay` later, and its canceller stops a superseded check
/// from ever judging. This file exercises that wiring once — arm, fire
/// after the delay, and a cancelled check that judges nothing — paying
/// the real 3.5 s exactly once so the suite stays fast.
final class VerifyDelayTests: XCTestCase {
    private let canvas = TilingSpaceKey(
        screen: ScreenID(rawValue: 1), space: SpaceID(rawValue: 10))
    /// Where the writes want the window.
    private let target = CGRect(x: 0, y: 500, width: 840, height: 500)
    /// Where the silently ignoring app keeps it.
    private let unmoved = CGRect(x: 0, y: 0, width: 100, height: 100)

    func testTheProductionSchedulerFiresAfterTheDelayAndACancelledCheckJudgesNothing() {
        let gateway = FakeWindowGateway()
        let first = gateway.addWindow(frame: unmoved)
        let second = gateway.addWindow(frame: unmoved)
        // The app accepts both writes and never moves: the dominant
        // real-world silent-ignore shape.
        gateway.silentIgnore = [first, second]
        let handles: [WindowID: WindowHandle] = [1: first, 2: second]
        var paid: [(id: WindowID, consequence: WriteExpectations.Consequence)] = []
        let armed = Date()
        var elapsed: TimeInterval = 0
        let fired = expectation(description: "the armed check judges its write")
        // The production scheduler is left at its default: the delay and
        // the main-queue wiring are what this test is about.
        let expectations = WriteExpectations(
            gateway: gateway,
            liveFrameOf: { id in handles[id].flatMap { gateway.frame(of: $0) } },
            onConsequence: { id, consequence in
                paid.append((id, consequence))
                if id == 1 {
                    elapsed = Date().timeIntervalSince(armed)
                    fired.fulfill()
                }
            })

        // Arm: win 1 stays armed and must be judged one delay later.
        XCTAssertEqual(
            expectations.write(
                1, handle: first, to: target, on: canvas, consequence: .slotCommit),
            .written)
        // Win 2 is armed and immediately forgotten: the canceller the
        // production scheduler returned must stop its work item.
        XCTAssertEqual(
            expectations.write(
                2, handle: second, to: target, on: canvas, consequence: .slotCommit),
            .written)
        expectations.forget(2)
        // The same canceller probed bare: a scheduled check cancelled at
        // once must never fire its block at all.
        var bareFired = false
        let cancelBare = WriteExpectations.scheduleCheckOnMain { bareFired = true }
        cancelBare()

        wait(for: [fired], timeout: WriteExpectations.checkDelay + 2)
        XCTAssertGreaterThanOrEqual(
            elapsed, WriteExpectations.checkDelay,
            "the check fires after the verify delay, never before it")

        // Win 2's deadline has now passed too: its cancelled check must
        // have judged nothing.
        let quiet = expectation(description: "the cancelled check stays silent")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { quiet.fulfill() }
        wait(for: [quiet], timeout: 1)
        XCTAssertEqual(paid.map(\.id), [1], "only the still-armed write paid a consequence")
        XCTAssertEqual(paid.first?.consequence, .slotCommit)
        XCTAssertFalse(bareFired, "the production canceller stops the scheduled work item")
    }
}
