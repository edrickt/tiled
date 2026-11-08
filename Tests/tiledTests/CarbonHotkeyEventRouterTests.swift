import Carbon.HIToolbox
import XCTest
@testable import tiled

/// The Carbon router's resolve-and-hop step, driven directly. No Carbon
/// event is synthesized and no live application event target is touched:
/// the installer is the same no-op seam the registration suite uses.
final class CarbonHotkeyEventRouterTests: XCTestCase {
    func testDispatchResolvesTheHotkeyIDAndDeliversOnTheMainQueue() {
        let router = CarbonHotkeyEventRouter(installer: { noErr })
        let delivered = expectation(description: "action delivered")
        var actions: [HotkeyAction] = []

        let status = router.dispatch(hotKeyID: SlotKey.bottomRight.hotkeyID) { action in
            actions.append(action)
            delivered.fulfill()
        }

        XCTAssertEqual(status, noErr, "a recognized id is handled")
        XCTAssertTrue(actions.isEmpty, "the handler runs after the main-queue hop")
        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(actions, [.slotKey(.bottomRight)])
    }

    func testDispatchRejectsAnUnknownHotkeyIDWithoutDelivering() {
        let router = CarbonHotkeyEventRouter(installer: { noErr })
        var actions: [HotkeyAction] = []

        let status = router.dispatch(hotKeyID: 10_000) { actions.append($0) }

        XCTAssertEqual(
            status, OSStatus(eventNotHandledErr),
            "an unknown id falls through to other apps")
        XCTAssertTrue(actions.isEmpty)
    }

    func testClearHandlerOnlyClearsForTheOwnerThatInstalledIt() {
        let router = CarbonHotkeyEventRouter(installer: { noErr })
        let oldOwner = NSObject()
        let replacement = NSObject()
        router.setHandler({ _ in }, owner: oldOwner)
        router.setHandler({ _ in }, owner: replacement)

        router.clearHandler(ifOwner: oldOwner)
        XCTAssertNotNil(
            router.handler,
            "a replaced service's teardown must not clear the live route")

        router.clearHandler(ifOwner: replacement)
        XCTAssertNil(router.handler)
    }

    /// A failed install is never the tap: the status is kept so the
    /// service can report the backend, not a lost combo.
    func testAFailedInstallReportsTheTapUnavailableWithItsStatus() {
        let router = CarbonHotkeyEventRouter(installer: { OSStatus(-1) })

        XCTAssertFalse(router.isEventTapAvailable)
        XCTAssertEqual(router.eventTapStatus, OSStatus(-1))
    }

    /// The process latch arms only on success, so a transient failure is
    /// retryable and a retry that succeeds becomes the live tap.
    func testARetryAfterATransientFailureInstallsTheTap() {
        var attempts = 0
        let router = CarbonHotkeyEventRouter(installer: {
            attempts += 1
            return attempts == 1 ? OSStatus(-1) : noErr
        })

        XCTAssertFalse(router.isEventTapAvailable)

        XCTAssertEqual(router.retryEventTapInstallIfNeeded(), noErr)

        XCTAssertTrue(router.isEventTapAvailable)
        XCTAssertEqual(attempts, 2, "the failed install left the latch unset")
        XCTAssertEqual(
            router.retryEventTapInstallIfNeeded(), noErr,
            "an available tap has nothing to retry")
        XCTAssertEqual(attempts, 2, "a successful tap is installed once")
    }
}
