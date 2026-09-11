import XCTest
@testable import tiled

/// LiveWindowGateway's observer-registration bookkeeping, extracted as a
/// pure value type so the recovery path after a failed registration is
/// testable without AX elements, observers, or a window server. The live
/// fake cannot reach this: `FakeWindowGateway.observe` records a dict
/// write and has no notion of registration at all.
final class ObservationRegistryTests: XCTestCase {
    // MARK: What a request needs

    func testFirstRequestForAPIDCreatesItsObserver() {
        var registry = LiveWindowGateway.ObservationRegistry()
        XCTAssertEqual(registry.begin(key: 1, pid: 100), .createObserver)
    }

    func testSecondElementOnAnObservedPIDReusesItsObserver() {
        var registry = LiveWindowGateway.ObservationRegistry()
        _ = registry.begin(key: 1, pid: 100)
        registry.finish(key: 1, pid: 100, outcome: .registered)
        XCTAssertEqual(registry.begin(key: 2, pid: 100), .register)
    }

    func testEachPIDKeepsItsOwnObserver() {
        var registry = LiveWindowGateway.ObservationRegistry()
        _ = registry.begin(key: 1, pid: 100)
        registry.finish(key: 1, pid: 100, outcome: .registered)
        XCTAssertEqual(registry.begin(key: 2, pid: 200), .createObserver)
    }

    func testObservedElementIsSkippedRatherThanDoubleRegistered() {
        var registry = LiveWindowGateway.ObservationRegistry()
        _ = registry.begin(key: 1, pid: 100)
        registry.finish(key: 1, pid: 100, outcome: .registered)
        XCTAssertEqual(registry.begin(key: 1, pid: 100), .skip)
        XCTAssertTrue(registry.isObserved(key: 1))
    }

    /// The same element requested twice before the AX calls return (a
    /// re-entrant observe) must not register twice.
    func testRequestWhileTheAttemptIsInFlightIsSkipped() {
        var registry = LiveWindowGateway.ObservationRegistry()
        XCTAssertEqual(registry.begin(key: 1, pid: 100), .createObserver)
        XCTAssertEqual(registry.begin(key: 1, pid: 100), .skip)
    }

    // MARK: Failure is never remembered as success

    /// The lockout this seam exists for: a failed registration used to be
    /// remembered, so every later observe for that element returned early
    /// and the window lost drag-resize for the life of the process.
    func testFailedRegistrationStaysRetryableOnTheExistingObserver() {
        var registry = LiveWindowGateway.ObservationRegistry()
        XCTAssertEqual(registry.begin(key: 1, pid: 100), .createObserver)
        registry.finish(key: 1, pid: 100, outcome: .registrationFailed)
        XCTAssertFalse(registry.isObserved(key: 1))
        // The observer itself exists now, so the retry reuses it.
        XCTAssertEqual(registry.begin(key: 1, pid: 100), .register)
    }

    func testFailedObserverCreationRetriesCreation() {
        var registry = LiveWindowGateway.ObservationRegistry()
        _ = registry.begin(key: 1, pid: 100)
        registry.finish(key: 1, pid: 100, outcome: .observerUnavailable)
        XCTAssertEqual(registry.begin(key: 1, pid: 100), .createObserver)
    }

    /// The registry believed the pid had an observer and the adapter found
    /// none: the belief must clear, or every later request would take the
    /// reuse path and find nothing there, which is the same lockout by a
    /// different route.
    func testObserverThatTurnedOutToBeGoneIsRecreated() {
        var registry = LiveWindowGateway.ObservationRegistry()
        _ = registry.begin(key: 1, pid: 100)
        registry.finish(key: 1, pid: 100, outcome: .registered)
        _ = registry.begin(key: 2, pid: 100)
        registry.finish(key: 2, pid: 100, outcome: .observerUnavailable)
        XCTAssertEqual(registry.begin(key: 3, pid: 100), .createObserver)
    }

    /// A retry after a partial failure re-adds both notifications; the one
    /// that already landed must not read as a failure, or the window would
    /// retry forever and never count as observed.
    func testFailedKeyBecomesObservedOnceARetryLands() {
        var registry = LiveWindowGateway.ObservationRegistry()
        _ = registry.begin(key: 1, pid: 100)
        registry.finish(key: 1, pid: 100, outcome: .registrationFailed)
        _ = registry.begin(key: 1, pid: 100)
        registry.finish(key: 1, pid: 100, outcome: .registered)
        XCTAssertTrue(registry.isObserved(key: 1))
        XCTAssertEqual(registry.begin(key: 1, pid: 100), .skip)
    }

    // MARK: Retry convergence

    func testAlreadyRegisteredCountsAsASuccessfulAdd() {
        XCTAssertTrue(
            LiveWindowGateway.ObservationRegistry.addSucceeded(.success))
        XCTAssertTrue(
            LiveWindowGateway.ObservationRegistry.addSucceeded(
                .notificationAlreadyRegistered))
    }

    func testRealRegistrationFailuresDoNotCountAsSuccess() {
        let failures: [AXError] = [
            .cannotComplete, .invalidUIElement, .notificationUnsupported,
            .apiDisabled, .failure,
        ]
        for status in failures {
            XCTAssertFalse(
                LiveWindowGateway.ObservationRegistry.addSucceeded(status),
                "\(status) must not read as registered")
        }
    }
}
