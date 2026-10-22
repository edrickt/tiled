import Carbon.HIToolbox
import XCTest
@testable import tiled

/// The Carbon router's resolve-and-hop step, driven directly. No Carbon
/// event is synthesized and no live application event target is touched:
/// the installer is the same no-op seam the registration suite uses.
final class CarbonHotkeyEventRouterTests: XCTestCase {
    func testDispatchResolvesTheHotkeyIDAndDeliversOnTheMainQueue() {
        let router = CarbonHotkeyEventRouter(installer: {})
        let delivered = expectation(description: "action delivered")
        var actions: [HotkeyAction] = []

        let status = router.dispatch(hotKeyID: Slot.bottomRight.hotkeyID) { action in
            actions.append(action)
            delivered.fulfill()
        }

        XCTAssertEqual(status, noErr, "a recognized id is handled")
        XCTAssertTrue(actions.isEmpty, "the handler runs after the main-queue hop")
        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(actions, [.slot(.bottomRight)])
    }

    func testDispatchRejectsAnUnknownHotkeyIDWithoutDelivering() {
        let router = CarbonHotkeyEventRouter(installer: {})
        var actions: [HotkeyAction] = []

        let status = router.dispatch(hotKeyID: 10_000) { actions.append($0) }

        XCTAssertEqual(
            status, OSStatus(eventNotHandledErr),
            "an unknown id falls through to other apps")
        XCTAssertTrue(actions.isEmpty)
    }

    func testClearHandlerOnlyClearsForTheOwnerThatInstalledIt() {
        let router = CarbonHotkeyEventRouter(installer: {})
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
}
