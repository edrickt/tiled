import Carbon.HIToolbox
import XCTest
@testable import tiled

/// Registration behavior at the registrar seam: which actions register,
/// which are skipped or recorded as failed, what reload tears down, and
/// what deinit releases. The fake answers every Carbon call, so no live
/// process or event handler is involved.
final class HotkeyRegistrationTests: XCTestCase {
    private var suiteName = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "tiledTests.HotkeyRegistration.\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    private func makeStore() -> HotkeyStore {
        HotkeyStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    private func makeService(
        store: HotkeyStore, registrar: FakeHotkeyRegistrar
    ) -> HotkeyService {
        HotkeyService(
            store: store, registrar: registrar, eventHandlerInstaller: {})
    }

    /// A fresh store has 17 slot bindings plus 5 app-action bindings, all
    /// enabled. Each must reach the registrar exactly once with its own
    /// live binding, Carbon id, and the 'TILD' signature.
    func testDefaultStoreRegistersEveryEnabledActionOnce() {
        let registrar = FakeHotkeyRegistrar()
        let store = makeStore()
        let service = makeService(store: store, registrar: registrar)

        XCTAssertEqual(Slot.allCases.count, 17)
        XCTAssertEqual(HotkeyAction.appActions.count, 5)
        XCTAssertEqual(registrar.requests.count, 22)
        XCTAssertEqual(registrar.activeTokens.count, 22)
        XCTAssertTrue(service.failedActions.isEmpty)
        XCTAssertEqual(
            registrar.requests(for: Slot.topLeft.hotkeyID),
            [HotkeyRequest(
                keyCode: UInt32(kVK_ANSI_U),
                modifiers: UInt32(shiftKey | optionKey | cmdKey),
                hotKeyID: Slot.topLeft.hotkeyID,
                signature: 0x54_49_4C_44)],
            "Top Left defaults to ⌥⇧⌘U")
        XCTAssertEqual(
            registrar.requests(for: HotkeyAction.undo.hotkeyID),
            [HotkeyRequest(
                keyCode: UInt32(kVK_ANSI_Z),
                modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
                hotKeyID: HotkeyAction.undo.hotkeyID,
                signature: 0x54_49_4C_44)],
            "Undo defaults to ⌃⌥⇧⌘Z")

        for action in HotkeyAction.allCases {
            let binding = store.binding(for: action)
            guard let keyCode = binding.keyCode else {
                XCTFail("\(action.title) should default to enabled")
                continue
            }
            XCTAssertEqual(
                registrar.requests(for: action.hotkeyID),
                [HotkeyRequest(
                    keyCode: keyCode, modifiers: binding.modifiers,
                    hotKeyID: action.hotkeyID, signature: 0x54_49_4C_44)],
                "\(action.title) must register its live binding once")
            XCTAssertNotNil(
                registrar.activeToken(for: action.hotkeyID),
                "\(action.title) must leave an active registration")
        }
    }

    /// Every action can be disabled; none may reach the registrar, and
    /// none is a failure.
    func testEveryDisabledActionIsSkipped() {
        let registrar = FakeHotkeyRegistrar()
        let store = makeStore()
        for action in HotkeyAction.allCases {
            store.set(HotkeyBinding(modifiers: 0, keyCode: nil), for: action)
        }

        let service = makeService(store: store, registrar: registrar)

        XCTAssertTrue(registrar.requests.isEmpty)
        XCTAssertTrue(registrar.activeTokens.isEmpty)
        XCTAssertTrue(service.failedActions.isEmpty)
    }

    /// A disabled binding registers nothing and is not a failure: it is a
    /// deliberate user choice, not a combo lost to another app.
    func testDisabledActionsRegisterNothingAndNeverEnterFailedActions() {
        let registrar = FakeHotkeyRegistrar()
        let store = makeStore()
        store.set(
            HotkeyBinding(modifiers: 0, keyCode: nil),
            for: .slot(.topLeft))
        store.set(
            HotkeyBinding(modifiers: 0, keyCode: nil),
            for: .resetSplitters)
        let service = makeService(store: store, registrar: registrar)

        XCTAssertTrue(registrar.requests(for: HotkeyAction.slot(.topLeft).hotkeyID).isEmpty)
        XCTAssertTrue(registrar.requests(for: HotkeyAction.resetSplitters.hotkeyID).isEmpty)
        XCTAssertEqual(registrar.requests.count, 20)
        XCTAssertEqual(registrar.activeTokens.count, 20)
        XCTAssertTrue(service.failedActions.isEmpty)
        XCTAssertNotNil(registrar.activeToken(for: HotkeyAction.slot(.topRight).hotkeyID))
        XCTAssertNotNil(registrar.activeToken(for: HotkeyAction.undo.hotkeyID))
    }

    /// A non-noErr answer names the action in `failedActions`, leaves no
    /// token behind for it, and does not stop the remaining actions.
    func testFailedRegistrationIsRecordedAndOtherActionsStillRegister() {
        let registrar = FakeHotkeyRegistrar()
        let store = makeStore()
        registrar.statusesByID[HotkeyAction.expand.hotkeyID] = OSStatus(-1)
        let service = makeService(store: store, registrar: registrar)

        XCTAssertEqual(service.failedActions, [.expand])
        XCTAssertNil(registrar.activeToken(for: HotkeyAction.expand.hotkeyID))
        XCTAssertEqual(registrar.requests.count, 22)
        XCTAssertEqual(registrar.activeTokens.count, 21)
        XCTAssertNotNil(registrar.activeToken(for: HotkeyAction.undo.hotkeyID))
    }

    /// `noErr` without a token is not a live registration: the action is
    /// a failure, not a silently unregistered success.
    func testNoErrWithoutATokenIsRecordedAsAFailure() {
        let registrar = FakeHotkeyRegistrar()
        let store = makeStore()
        registrar.nilTokenIDs.insert(HotkeyAction.expand.hotkeyID)

        let service = makeService(store: store, registrar: registrar)

        XCTAssertEqual(service.failedActions, [.expand])
        XCTAssertNil(registrar.activeToken(for: HotkeyAction.expand.hotkeyID))
        XCTAssertEqual(registrar.activeTokens.count, 21)
    }

    /// Reload retires the whole old set before registering the edited
    /// store, and a failure is recomputed both ways: one that clears on
    /// reload disappears, a new one appears.
    func testReloadUnregistersOldTokensAndRecomputesFailures() {
        let registrar = FakeHotkeyRegistrar()
        let store = makeStore()
        registrar.statusesByID[HotkeyAction.expand.hotkeyID] = OSStatus(-1)
        let service = makeService(store: store, registrar: registrar)

        let oldTokens = registrar.activeTokens
        XCTAssertEqual(oldTokens.count, 21)
        XCTAssertEqual(service.failedActions, [.expand])

        let rebound = HotkeyBinding(
            modifiers: UInt32(cmdKey), keyCode: UInt32(kVK_ANSI_A))
        store.set(rebound, for: .slot(.topLeft))
        store.set(
            HotkeyBinding(modifiers: 0, keyCode: nil),
            for: .undo)
        registrar.statusesByID[HotkeyAction.expand.hotkeyID] = noErr

        service.reload()

        XCTAssertEqual(registrar.unregisteredTokens.count, 21)
        XCTAssertTrue(oldTokens.allSatisfy { !$0.isActive })
        XCTAssertTrue(service.failedActions.isEmpty)
        XCTAssertEqual(registrar.requests.count, 43)
        XCTAssertEqual(registrar.activeTokens.count, 21)
        let reloadEvents = Array(registrar.events.dropFirst(22))
        XCTAssertEqual(
            reloadEvents.prefix(21).filter { $0.hasPrefix("unregister ") }.count, 21,
            "reload retires the whole old set before registering")
        XCTAssertTrue(
            reloadEvents.dropFirst(21).allSatisfy { $0.hasPrefix("register ") },
            "every new registration follows the teardown")
        XCTAssertNil(registrar.activeToken(for: HotkeyAction.undo.hotkeyID))
        XCTAssertNotNil(registrar.activeToken(for: HotkeyAction.expand.hotkeyID))
        XCTAssertEqual(
            registrar.requests(for: HotkeyAction.slot(.topLeft).hotkeyID).last,
            HotkeyRequest(
                keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey),
                hotKeyID: HotkeyAction.slot(.topLeft).hotkeyID,
                signature: 0x54_49_4C_44))
        // The disabled action was not retried on reload.
        XCTAssertEqual(registrar.requests(for: HotkeyAction.undo.hotkeyID).count, 1)

        registrar.statusesByID[HotkeyAction.slot(.topRight).hotkeyID] = OSStatus(-2)

        service.reload()

        XCTAssertEqual(registrar.unregisteredTokens.count, 42)
        XCTAssertEqual(service.failedActions, [.slot(.topRight)])
        XCTAssertEqual(registrar.activeTokens.count, 20)
        XCTAssertNil(
            registrar.activeToken(for: HotkeyAction.slot(.topRight).hotkeyID))
    }

    /// The class comment promises no registration outlives the service;
    /// deinit must retire every token it still holds.
    func testDeinitUnregistersEveryActiveToken() {
        let registrar = FakeHotkeyRegistrar()
        let store = makeStore()
        var service: HotkeyService? = makeService(store: store, registrar: registrar)
        weak var weakService = service

        XCTAssertEqual(registrar.activeTokens.count, 22)

        service = nil

        XCTAssertNil(weakService)
        XCTAssertTrue(registrar.activeTokens.isEmpty)
        XCTAssertEqual(registrar.unregisteredTokens.count, 22)
    }

    /// F29: the Carbon router is process-wide, but the action handler belongs
    /// to the service that installed it. Teardown must clear that handler so
    /// a dead service is never called.
    func testDeinitClearsTheRouterHandler() throws {
        let registrar = FakeHotkeyRegistrar()
        let store = makeStore()
        var service: HotkeyService? = makeService(store: store, registrar: registrar)
        let router = try XCTUnwrap(service?.router)
        service?.setHandler { _ in }
        XCTAssertNotNil(router.handler)

        service = nil

        XCTAssertNil(router.handler, "a dead service leaves no handler behind")
    }

    /// A replacement service claims the same process-wide route; the old
    /// service's teardown must leave that newer handler installed.
    func testAReplacementServiceKeepsItsHandlerWhenTheOldOneTearsDown() {
        let registrar = FakeHotkeyRegistrar()
        let store = makeStore()
        let router = CarbonHotkeyEventRouter(installer: {})
        var old: HotkeyService? = HotkeyService(
            store: store, registrar: registrar, router: router)
        old?.setHandler { _ in }
        let replacement = HotkeyService(
            store: store, registrar: registrar, router: router)
        replacement.setHandler { _ in }

        old = nil

        XCTAssertNotNil(
            router.handler, "the replacement service owns the live route")
    }
}

/// Records every registration request and answers from a per-action table.
/// Tokens are stand-ins for Carbon's `EventHotKeyRef`; a token only leaves
/// the active set through `unregister`, so forgotten teardown is visible.
private final class FakeHotkeyRegistrar: HotkeyRegistrar {
    final class Token: HotkeyRegistration {
        let request: HotkeyRequest
        fileprivate(set) var isActive = true

        init(request: HotkeyRequest) {
            self.request = request
        }
    }

    private(set) var requests: [HotkeyRequest] = []
    private(set) var issuedTokens: [Token] = []
    private(set) var unregisteredTokens: [Token] = []
    private(set) var events: [String] = []
    var statusesByID: [UInt32: OSStatus] = [:]
    var nilTokenIDs: Set<UInt32> = []

    var activeTokens: [Token] {
        issuedTokens.filter(\.isActive)
    }

    func requests(for hotKeyID: UInt32) -> [HotkeyRequest] {
        requests.filter { $0.hotKeyID == hotKeyID }
    }

    func activeToken(for hotKeyID: UInt32) -> Token? {
        activeTokens.first { $0.request.hotKeyID == hotKeyID }
    }

    func register(
        _ request: HotkeyRequest
    ) -> (status: OSStatus, registration: HotkeyRegistration?) {
        requests.append(request)
        events.append("register \(request.hotKeyID)")
        let status = statusesByID[request.hotKeyID] ?? noErr
        guard status == noErr, !nilTokenIDs.contains(request.hotKeyID) else {
            return (status, nil)
        }
        let token = Token(request: request)
        issuedTokens.append(token)
        return (status, token)
    }

    func unregister(_ registration: HotkeyRegistration) {
        guard let token = registration as? Token else { return }
        events.append("unregister \(token.request.hotKeyID)")
        token.isActive = false
        unregisteredTokens.append(token)
    }
}
