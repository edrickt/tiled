import Carbon.HIToolbox
import XCTest

@testable import tiled

/// The Carbon event handler must live exactly as long as the service that
/// installed it: one handler per instance, removed on deinit, with its
/// context retained the whole time. The old design installed a handler
/// once behind a process-wide flag and never removed it, so a dead
/// service left a handler pointing at a freed context (a use-after-free
/// on the next hotkey press) and a replacement service installed nothing.
///
/// The Carbon calls themselves need a live event loop, so the ownership
/// is exercised through injected install/remove closures; the loop the
/// fix is accountable to is this lifetime contract, which the real calls
/// share.
final class CarbonEventHandlerTests: XCTestCase {
    private let fakeRef = OpaquePointer(bitPattern: 0x1)!

    func testEachInstanceInstallsItsOwnHandler() {
        let ref = fakeRef
        var installs = 0
        let first = CarbonEventHandler(
            payload: NSObject(),
            install: { _, handler in installs += 1; handler = ref },
            remove: { _ in })
        let second = CarbonEventHandler(
            payload: NSObject(),
            install: { _, handler in installs += 1; handler = ref },
            remove: { _ in })

        _ = first
        _ = second
        XCTAssertEqual(
            installs, 2,
            "a second instance must install its own handler, not reuse the first's")
    }

    func testHandlerIsRemovedWhenItsInstanceDies() {
        let ref = fakeRef
        var removals: [EventHandlerRef] = []
        var handler: CarbonEventHandler<NSObject>? = CarbonEventHandler(
            payload: NSObject(),
            install: { _, handler in handler = ref },
            remove: { removals.append($0) })
        XCTAssertNotNil(handler)

        handler = nil

        XCTAssertEqual(removals, [ref], "deinit must unregister the handler")
    }

    func testAFailedInstallRemovesNothing() {
        var removals = 0
        var handler: CarbonEventHandler<NSObject>? = CarbonEventHandler(
            payload: NSObject(),
            install: { _, handler in handler = nil },
            remove: { _ in removals += 1 })
        XCTAssertNotNil(handler)

        handler = nil

        XCTAssertEqual(removals, 0, "a handler that never installed must not be removed")
    }

    func testInstalledHandlerRetainsItsContext() {
        weak var weakPayload: NSObject?
        var handler: CarbonEventHandler<NSObject>?
        autoreleasepool {
            let payload = NSObject()
            weakPayload = payload
            let ref = fakeRef
            handler = CarbonEventHandler(
                payload: payload,
                install: { _, handler in handler = ref },
                remove: { _ in })
        }
        XCTAssertNotNil(
            weakPayload,
            "the installed handler must keep its context alive for the callback")

        handler = nil
        XCTAssertNil(weakPayload, "removing the handler must release the context")
    }
}
