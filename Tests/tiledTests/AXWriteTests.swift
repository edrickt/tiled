import CoreGraphics
import XCTest
@testable import tiled

/// LiveWindowGateway's AX write policy — the transient-failure class and
/// backoff, and the write pair's snapshot and put-back — extracted as
/// pure functions over injected messages so a half-applied frame write
/// is testable without AX elements or a busy app.
final class AXWriteTests: XCTestCase {
    /// A scripted window the write pair pushes against: every message
    /// records itself and lands unless the script refuses it — an app
    /// that refuses one attribute on every attempt while honouring the
    /// other. The frame is plain geometry; the policy only ever writes
    /// back what it read.
    private final class StubWindow {
        private(set) var frame: CGRect
        /// Position writes the app refuses (by value).
        var refusesPosition: (CGPoint) -> Bool = { _ in false }
        /// Size writes the app refuses (by value).
        var refusesSize: (CGSize) -> Bool = { _ in false }
        /// Every position write attempted, in order — push and put-back.
        private(set) var positionWrites: [CGPoint] = []
        /// Every size write attempted, in order — push and put-back.
        private(set) var sizeWrites: [CGSize] = []
        /// Which attribute each message was for, in order.
        private(set) var order: [String] = []

        init(frame: CGRect) {
            self.frame = frame
        }

        func push(position: CGPoint, size: CGSize) -> AXError? {
            LiveWindowGateway.AXWrite.pushFrame(
                position: position, size: size,
                readPosition: { self.frame.origin },
                readSize: { self.frame.size },
                writePosition: { value in
                    self.order.append("position")
                    self.positionWrites.append(value)
                    if self.refusesPosition(value) { return .failure }
                    self.frame.origin = value
                    return .success
                },
                writeSize: { value in
                    self.order.append("size")
                    self.sizeWrites.append(value)
                    if self.refusesSize(value) { return .failure }
                    self.frame.size = value
                    return .success
                },
                sleep: { _ in })
        }
    }

    // MARK: Retryable error class

    func testCannotCompleteIsRetryable() {
        // The busy-app failure: the main thread could not service the
        // message right now. The classic flaky swap cause.
        XCTAssertTrue(LiveWindowGateway.AXWrite.isRetryable(.cannotComplete))
    }

    func testPermanentFailuresAreNotRetryable() {
        // Refusals and dead elements: retrying changes nothing.
        let permanent: [AXError] = [
            .failure, .attributeUnsupported, .invalidUIElement,
            .apiDisabled, .notificationUnsupported,
            .parameterizedAttributeUnsupported, .notEnoughPrecision,
        ]
        for error in permanent {
            XCTAssertFalse(
                LiveWindowGateway.AXWrite.isRetryable(error),
                "\(error) must not retry: it is permanent")
        }
    }

    // MARK: Backoff

    func testBackoffDoublesPerAttempt() {
        let policy = LiveWindowGateway.AXWrite.self
        XCTAssertEqual(policy.delay(forAttempt: 0), 0.1, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(forAttempt: 1), 0.2, accuracy: 1e-9)
        // Two retries cap the total added latency at 0.3s per write.
        XCTAssertEqual(
            policy.delay(forAttempt: 0) + policy.delay(forAttempt: 1), 0.3,
            accuracy: 1e-9)
    }

    // MARK: retrying

    func testSuccessOnFirstAttemptDoesNotSleep() {
        var calls = 0
        var slept: [TimeInterval] = []
        let error = LiveWindowGateway.AXWrite.retrying(
            operation: {
                calls += 1
                return .success
            },
            sleep: { slept.append($0) })
        XCTAssertNil(error)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(slept.isEmpty, "a first-try success must never sleep")
    }

    func testTransientFailureRetriesAndSucceeds() {
        var calls = 0
        var slept: [TimeInterval] = []
        let error = LiveWindowGateway.AXWrite.retrying(
            operation: { () -> AXError in
                calls += 1
                return calls < 3 ? .cannotComplete : .success
            },
            sleep: { slept.append($0) })
        XCTAssertNil(error, "success on attempt 3 must read as success")
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(slept, [0.1, 0.2], "backoff doubles per attempt")
    }

    func testExhaustedTransientFailureReturnsLastError() {
        var calls = 0
        var slept: [TimeInterval] = []
        let error = LiveWindowGateway.AXWrite.retrying(
            operation: { () -> AXError in
                calls += 1
                return .cannotComplete
            },
            sleep: { slept.append($0) })
        XCTAssertEqual(error, .cannotComplete)
        XCTAssertEqual(calls, LiveWindowGateway.AXWrite.maxAttempts)
        // No sleep after the final attempt: nothing follows to wait for.
        XCTAssertEqual(slept, [0.1, 0.2])
    }

    func testPermanentFailureFailsImmediately() {
        var calls = 0
        var slept: [TimeInterval] = []
        let error = LiveWindowGateway.AXWrite.retrying(
            operation: { () -> AXError in
                calls += 1
                return .attributeUnsupported
            },
            sleep: { slept.append($0) })
        XCTAssertEqual(error, .attributeUnsupported)
        XCTAssertEqual(calls, 1, "a permanent refusal must not retry")
        XCTAssertTrue(slept.isEmpty)
    }

    func testTransientThenPermanentStopsAtThePermanentError() {
        // A busy app that eventually reports a real refusal: the retry
        // must surface the refusal, not spin to exhaustion.
        var calls = 0
        var slept: [TimeInterval] = []
        let error = LiveWindowGateway.AXWrite.retrying(
            operation: { () -> AXError in
                calls += 1
                return calls == 1 ? .cannotComplete : .failure
            },
            sleep: { slept.append($0) })
        XCTAssertEqual(error, .failure)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(slept, [0.1], "only the transient failure sleeps")
    }

    // MARK: The restore decision

    func testRestoreDecisionPutsBackWhateverLanded() {
        // The pair is one logical push: whenever it fails after landing
        // anything, the pre-write frame goes back — exactly one landed is
        // the half-moved window, and both landing on different attempts
        // is the same disagreement in a fuller frame. Nothing landed is
        // already left alone; both landed on one attempt is a success.
        let policy = LiveWindowGateway.AXWrite.self
        XCTAssertTrue(
            policy.needsRestore(positionLanded: true, sizeLanded: false, failed: true))
        XCTAssertTrue(
            policy.needsRestore(positionLanded: false, sizeLanded: true, failed: true))
        XCTAssertTrue(
            policy.needsRestore(positionLanded: true, sizeLanded: true, failed: true))
        XCTAssertFalse(
            policy.needsRestore(positionLanded: false, sizeLanded: false, failed: true))
        XCTAssertFalse(
            policy.needsRestore(positionLanded: true, sizeLanded: true, failed: false))
    }

    // MARK: The write pair's put-back

    func testPushFramePutsBackTheWholeFrameWhenOnlySizeLanded() {
        // The ticket's shape: the position write fails on every attempt
        // while the size lands. The window must end at its full pre-write
        // frame, not resized at its old origin.
        let preWrite = CGRect(x: 10, y: 20, width: 300, height: 200)
        let target = CGRect(x: 500, y: 400, width: 800, height: 600)
        let window = StubWindow(frame: preWrite)
        window.refusesPosition = { _ in true }

        let error = window.push(position: target.origin, size: target.size)

        XCTAssertEqual(error, .failure, "the write reads as refused")
        XCTAssertEqual(window.frame, preWrite, "the landed size is put back whole")
        XCTAssertEqual(
            window.sizeWrites, [target.size, preWrite.size],
            "the size put-back reasserts the pre-write size")
        XCTAssertEqual(
            window.positionWrites, [target.origin, preWrite.origin],
            "the put-back is the full frame, not just the landed half")
    }

    func testPushFramePutsBackTheWholeFrameWhenOnlyPositionLanded() {
        // The regression shape: the position lands and the size is
        // refused on every attempt — the window must not stay moved at
        // its old size.
        let preWrite = CGRect(x: 10, y: 20, width: 300, height: 200)
        let target = CGRect(x: 500, y: 400, width: 800, height: 600)
        let window = StubWindow(frame: preWrite)
        window.refusesSize = { _ in true }

        let error = window.push(position: target.origin, size: target.size)

        XCTAssertEqual(error, .failure, "the write reads as refused")
        XCTAssertEqual(window.frame, preWrite, "the landed origin is put back whole")
        XCTAssertEqual(
            window.positionWrites, [target.origin, preWrite.origin],
            "the origin put-back reasserts the pre-write origin")
        XCTAssertEqual(
            window.sizeWrites, [target.size, preWrite.size],
            "the put-back is the full frame, not just the landed half")
    }

    func testPushFrameSuccessLeavesTheTargetAndWritesNothingBack() {
        let preWrite = CGRect(x: 10, y: 20, width: 300, height: 200)
        let target = CGRect(x: 500, y: 400, width: 800, height: 600)
        let window = StubWindow(frame: preWrite)

        let error = window.push(position: target.origin, size: target.size)

        XCTAssertNil(error)
        XCTAssertEqual(window.frame, target)
        XCTAssertEqual(window.positionWrites, [target.origin], "no put-back on success")
        XCTAssertEqual(window.sizeWrites, [target.size], "no put-back on success")
    }

    func testPushFrameThatLandedNothingPutsNothingBack() {
        // A window the app refuses to move or resize is already left
        // alone: a put-back write would be noise.
        let preWrite = CGRect(x: 10, y: 20, width: 300, height: 200)
        let target = CGRect(x: 500, y: 400, width: 800, height: 600)
        let window = StubWindow(frame: preWrite)
        window.refusesPosition = { _ in true }
        window.refusesSize = { _ in true }

        let error = window.push(position: target.origin, size: target.size)

        XCTAssertEqual(error, .failure)
        XCTAssertEqual(window.frame, preWrite, "left where it was")
        XCTAssertEqual(window.positionWrites, [target.origin], "no put-back")
        XCTAssertEqual(window.sizeWrites, [target.size], "no put-back")
    }

    func testPushFrameWritesPositionBeforeSize() {
        // AX size-sets anchor the top-left at the current position:
        // sizing first can push a bottom window past the screen bottom
        // into a clamp the later position write cannot undo.
        let preWrite = CGRect(x: 10, y: 20, width: 300, height: 200)
        let target = CGRect(x: 500, y: 400, width: 800, height: 600)
        let window = StubWindow(frame: preWrite)

        _ = window.push(position: target.origin, size: target.size)

        XCTAssertEqual(window.order, ["position", "size"])
    }
}
