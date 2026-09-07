import XCTest
@testable import tiled

/// LiveWindowGateway's AX write retry policy, extracted as pure functions
/// so the transient-failure class and backoff are testable without AX
/// elements or a busy app.
final class AXWriteTests: XCTestCase {
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
                "\(error) must not retry — it is permanent")
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
}
