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

    /// A fresh store has 11 slot-key bindings plus 6 app-action bindings, all
    /// enabled. Each must reach the registrar exactly once with its own
    /// live binding, Carbon id, and the 'TILD' signature.
    func testDefaultStoreRegistersEveryEnabledActionOnce() {
        let registrar = FakeHotkeyRegistrar()
        let store = makeStore()
        let service = makeService(store: store, registrar: registrar)

        XCTAssertEqual(SlotKey.allCases.count, 11)
        XCTAssertEqual(HotkeyAction.appActions.count, 6)
        XCTAssertEqual(registrar.requests.count, 17)
        XCTAssertEqual(registrar.activeTokens.count, 17)
        XCTAssertTrue(service.failedActions.isEmpty)
        XCTAssertEqual(
            registrar.requests(for: SlotKey.topLeft.hotkeyID),
            [HotkeyRequest(
                keyCode: UInt32(kVK_ANSI_U),
                modifiers: UInt32(shiftKey | optionKey),
                hotKeyID: SlotKey.topLeft.hotkeyID,
                signature: 0x54_49_4C_44)],
            "Top Left defaults to ⌥⇧U")
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
            for: .slotKey(.topLeft))
        store.set(
            HotkeyBinding(modifiers: 0, keyCode: nil),
            for: .resetSplitters)
        let service = makeService(store: store, registrar: registrar)

        XCTAssertTrue(registrar.requests(for: HotkeyAction.slotKey(.topLeft).hotkeyID).isEmpty)
        XCTAssertTrue(registrar.requests(for: HotkeyAction.resetSplitters.hotkeyID).isEmpty)
        XCTAssertEqual(registrar.requests.count, 15)
        XCTAssertEqual(registrar.activeTokens.count, 15)
        XCTAssertTrue(service.failedActions.isEmpty)
        XCTAssertNotNil(registrar.activeToken(for: HotkeyAction.slotKey(.topRight).hotkeyID))
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
        XCTAssertEqual(registrar.requests.count, 17)
        XCTAssertEqual(registrar.activeTokens.count, 16)
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
        XCTAssertEqual(registrar.activeTokens.count, 16)
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
        XCTAssertEqual(oldTokens.count, 16)
        XCTAssertEqual(service.failedActions, [.expand])

        let rebound = HotkeyBinding(
            modifiers: UInt32(cmdKey), keyCode: UInt32(kVK_ANSI_A))
        store.set(rebound, for: .slotKey(.topLeft))
        store.set(
            HotkeyBinding(modifiers: 0, keyCode: nil),
            for: .undo)
        registrar.statusesByID[HotkeyAction.expand.hotkeyID] = noErr

        service.reload()

        XCTAssertEqual(registrar.unregisteredTokens.count, 16)
        XCTAssertTrue(oldTokens.allSatisfy { !$0.isActive })
        XCTAssertTrue(service.failedActions.isEmpty)
        XCTAssertEqual(registrar.requests.count, 33)
        XCTAssertEqual(registrar.activeTokens.count, 16)
        let reloadEvents = Array(registrar.events.dropFirst(17))
        XCTAssertEqual(
            reloadEvents.prefix(16).filter { $0.hasPrefix("unregister ") }.count, 16,
            "reload retires the whole old set before registering")
        XCTAssertTrue(
            reloadEvents.dropFirst(16).allSatisfy { $0.hasPrefix("register ") },
            "every new registration follows the teardown")
        XCTAssertNil(registrar.activeToken(for: HotkeyAction.undo.hotkeyID))
        XCTAssertNotNil(registrar.activeToken(for: HotkeyAction.expand.hotkeyID))
        XCTAssertEqual(
            registrar.requests(for: HotkeyAction.slotKey(.topLeft).hotkeyID).last,
            HotkeyRequest(
                keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey),
                hotKeyID: HotkeyAction.slotKey(.topLeft).hotkeyID,
                signature: 0x54_49_4C_44))
        // The disabled action was not retried on reload.
        XCTAssertEqual(registrar.requests(for: HotkeyAction.undo.hotkeyID).count, 1)

        registrar.statusesByID[HotkeyAction.slotKey(.topRight).hotkeyID] = OSStatus(-2)

        service.reload()

        XCTAssertEqual(registrar.unregisteredTokens.count, 32)
        XCTAssertEqual(service.failedActions, [.slotKey(.topRight)])
        XCTAssertEqual(registrar.activeTokens.count, 15)
        XCTAssertNil(
            registrar.activeToken(for: HotkeyAction.slotKey(.topRight).hotkeyID))
    }

    /// The class comment promises no registration outlives the service;
    /// deinit must retire every token it still holds.
    func testDeinitUnregistersEveryActiveToken() {
        let registrar = FakeHotkeyRegistrar()
        let store = makeStore()
        var service: HotkeyService? = makeService(store: store, registrar: registrar)
        weak var weakService = service

        XCTAssertEqual(registrar.activeTokens.count, 17)

        service = nil

        XCTAssertNil(weakService)
        XCTAssertTrue(registrar.activeTokens.isEmpty)
        XCTAssertEqual(registrar.unregisteredTokens.count, 17)
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

    /// Recording a shortcut needs every global registration retired: a
    /// registered combo is consumed before the recorder's local monitor.
    /// Suspend retires the whole set; resume registers the store again
    /// exactly once, so no combo is left dead after a recording.
    func testSuspendRetiresEveryRegistrationAndResumeRestoresThemOnce() {
        let registrar = FakeHotkeyRegistrar()
        let store = makeStore()
        let service = makeService(store: store, registrar: registrar)
        XCTAssertEqual(registrar.activeTokens.count, 17)

        service.suspend()

        XCTAssertTrue(service.isSuspended)
        XCTAssertTrue(registrar.activeTokens.isEmpty, "armed: nothing may reach Carbon")
        XCTAssertEqual(registrar.unregisteredTokens.count, 17, "every token is retired")
        service.suspend()
        XCTAssertEqual(registrar.unregisteredTokens.count, 17, "suspend is idempotent")
        XCTAssertEqual(registrar.requests.count, 17, "suspend never registers")

        service.resume()

        XCTAssertFalse(service.isSuspended)
        XCTAssertEqual(registrar.activeTokens.count, 17, "disarm restores every binding")
        XCTAssertEqual(registrar.requests.count, 34, "resume registers exactly once")
        service.resume()
        XCTAssertEqual(
            registrar.requests.count, 34,
            "overlapping disarm paths never register a second pass")
    }

    /// Resume recomputes the failure list from the registration pass, so
    /// a combo another app owns still surfaces beside its recorder after
    /// a recording ends, and one freed while suspended clears.
    func testResumeRecomputesFailedActions() {
        let registrar = FakeHotkeyRegistrar()
        let store = makeStore()
        registrar.statusesByID[HotkeyAction.expand.hotkeyID] = OSStatus(-1)
        let service = makeService(store: store, registrar: registrar)
        XCTAssertEqual(service.failedActions, [.expand])

        service.suspend()
        registrar.statusesByID[HotkeyAction.expand.hotkeyID] = noErr
        registrar.statusesByID[HotkeyAction.undo.hotkeyID] = OSStatus(-2)
        XCTAssertEqual(
            service.failedActions, [.expand],
            "suspending does not invent a new registration result")

        service.resume()

        XCTAssertEqual(
            service.failedActions, [.undo],
            "resume's pass replaces the suspended set with the live result")
    }

    /// A binding edit while the recorder is armed re-registers through the
    /// tab's reload; that reload must not put Carbon back ahead of the
    /// recorder. Resume is the one pass that registers.
    func testReloadWhileSuspendedStaysRetiredUntilResume() {
        let registrar = FakeHotkeyRegistrar()
        let store = makeStore()
        let service = makeService(store: store, registrar: registrar)

        service.suspend()
        let rebound = HotkeyBinding(
            modifiers: UInt32(cmdKey), keyCode: UInt32(kVK_ANSI_A))
        store.set(rebound, for: .slotKey(.topLeft))
        service.reload()

        XCTAssertTrue(registrar.activeTokens.isEmpty, "a suspended reload stays retired")
        XCTAssertEqual(registrar.requests.count, 17, "no registration slipped through")

        service.resume()

        XCTAssertEqual(registrar.activeTokens.count, 17)
        XCTAssertEqual(
            registrar.requests(for: HotkeyAction.slotKey(.topLeft).hotkeyID).last,
            HotkeyRequest(
                keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey),
                hotKeyID: HotkeyAction.slotKey(.topLeft).hotkeyID,
                signature: 0x54_49_4C_44),
            "resume registers the store as it stands after the edit")
    }
}

/// Records every registration request and answers from a per-action table.
/// Tokens are stand-ins for Carbon's `EventHotKeyRef`; a token only leaves
/// the active set through `unregister`, so forgotten teardown is visible.
final class FakeHotkeyRegistrar: HotkeyRegistrar {
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
