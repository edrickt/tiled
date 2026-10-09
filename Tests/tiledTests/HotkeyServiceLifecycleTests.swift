import Carbon.HIToolbox
import XCTest

@testable import tiled

/// A HotkeyService owns its global hotkey registrations for its whole life
/// and must give every one of them back at the end of it: teardown (or
/// replacing the service) must leave nothing registered — a phantom
/// registration swallows its combos system-wide with no handler behind it,
/// and a replacement service double-registers the combos it re-registers.
///
/// The Carbon calls need a live event loop, so the lifecycle runs against
/// the injected register/unregister (and install/remove) seams — the same
/// shape `CarbonEventHandler` takes for its handler's lifetime. The loop
/// the contract is accountable to is the ledger the real calls share: what
/// was registered is unregistered, and every combo is registered exactly
/// once at any moment.
final class HotkeyServiceLifecycleTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: HotkeyStore!
    private var layer: FakeHotkeyLayer!

    override func setUp() {
        super.setUp()
        suiteName = "HotkeyServiceLifecycleTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = HotkeyStore(defaults: defaults)
        layer = FakeHotkeyLayer()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        layer = nil
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeService(layer: FakeHotkeyLayer, store: HotkeyStore) -> HotkeyService {
        HotkeyService(
            store: store,
            register: layer.register,
            unregister: layer.unregister,
            install: layer.install,
            remove: layer.remove)
    }

    /// Register: one register call per enabled action under that action's
    /// hotkey id, carrying the store's combo; a disabled action registers
    /// nothing and warns about nothing, and a refused registration keeps
    /// no registration while surfacing in failedActions (the menu and
    /// Shortcuts tab warn about it).
    func testInitRegistersEveryEnabledActionAndSurfacesRefusedOnes() throws {
        store.set(HotkeyBinding(modifiers: 0, keyCode: nil), for: .undo)
        layer.refuseCombos = [FakeHotkeyLayer.Combo(
            keyCode: HotkeyService.expandKeyCode,
            modifiers: HotkeyService.expandModifiers)]

        let service = makeService(layer: layer, store: store)

        let enabled = HotkeyAction.allCases.filter { $0 != .undo }
        XCTAssertEqual(
            Set(layer.registerCalls.map(\.hotKeyID)),
            Set(enabled.map(\.hotkeyID)),
            "every enabled action registers, each under its own hotkey id")
        for action in enabled {
            let binding = store.binding(for: action)
            let combo = FakeHotkeyLayer.Combo(
                keyCode: try XCTUnwrap(binding.keyCode), modifiers: binding.modifiers)
            XCTAssertTrue(
                layer.registerCalls.contains { $0.hotKeyID == action.hotkeyID && $0.combo == combo },
                "\(action.title) must register its store combo")
        }
        XCTAssertEqual(
            service.failedActions, [.expand],
            "a refused registration surfaces in failedActions")
        XCTAssertFalse(
            layer.live.contains { $0.hotKeyID == HotkeyAction.expand.hotkeyID },
            "a refused combo holds no registration")
    }

    /// Reload: every registration is given back before the store is read
    /// again — the old refs are unregistered (no combo ends up registered
    /// twice), the store's current combos are what is registered, and
    /// failedActions is recomputed from the new round, so a newly freed
    /// action stops warning.
    func testReloadGivesBackEveryRegistrationAndReregistersFromTheStore() throws {
        layer.refuseCombos = [FakeHotkeyLayer.Combo(
            keyCode: HotkeyService.expandKeyCode,
            modifiers: HotkeyService.expandModifiers)]
        let service = makeService(layer: layer, store: store)
        XCTAssertEqual(service.failedActions, [.expand])
        let firstRoundRefs = Set(layer.live.map(\.ref))

        // The user rebinds Expand to a free combo; the conflict is gone.
        let rebound = HotkeyBinding(
            modifiers: HotkeyService.expandModifiers, keyCode: UInt32(kVK_ANSI_Q))
        store.set(rebound, for: .expand)
        layer.refuseCombos = []
        service.reload()

        let reboundCombo = FakeHotkeyLayer.Combo(
            keyCode: try XCTUnwrap(rebound.keyCode), modifiers: rebound.modifiers)
        XCTAssertEqual(service.failedActions, [],
            "failedActions is recomputed from the new round")
        XCTAssertTrue(
            layer.live.allSatisfy { !firstRoundRefs.contains($0.ref) },
            "every registration is given back before the store is read again")
        XCTAssertEqual(layer.live.count, HotkeyAction.allCases.count,
            "one registration per enabled action, never two")
        XCTAssertTrue(
            layer.live.contains {
                $0.hotKeyID == HotkeyAction.expand.hotkeyID && $0.combo == reboundCombo
            },
            "the store's current combo is what is registered after reload")
    }

    /// Teardown: every registration the service installed is given back
    /// when it dies — the combos are free system-wide, nothing registered
    /// to swallow keys with no handler left behind it.
    func testTeardownUnregistersEveryRegistrationTheServiceInstalled() {
        var service: HotkeyService? = makeService(layer: layer, store: store)
        let registered = Set(layer.live.map(\.ref))
        XCTAssertEqual(registered.count, HotkeyAction.allCases.count)
        XCTAssertNotNil(service)

        service = nil

        XCTAssertTrue(layer.live.isEmpty,
            "a dead service must leave nothing registered")
        XCTAssertEqual(Set(layer.unregistered), registered,
            "every registration the service installed is given back")
    }

    /// A replacement service registering the same combos finds them free:
    /// every registration succeeds (failedActions is empty — no
    /// registration failure) and each combo holds exactly one
    /// registration, so one press dispatches exactly once (no double
    /// dispatch).
    func testAReplacementServiceRegistersTheSameCombosExactlyOnce() throws {
        var service: HotkeyService? = makeService(layer: layer, store: store)
        XCTAssertNotNil(service)
        service = nil

        let replacement = makeService(layer: layer, store: store)

        XCTAssertEqual(replacement.failedActions, [],
            "teardown leaves the combos free to register again")
        for action in HotkeyAction.allCases {
            let binding = store.binding(for: action)
            let combo = FakeHotkeyLayer.Combo(
                keyCode: try XCTUnwrap(binding.keyCode), modifiers: binding.modifiers)
            XCTAssertEqual(
                layer.dispatchesPerPress(combo), 1,
                "\(action.title): one press must dispatch exactly once")
        }
    }

    /// The service's whole Carbon surface runs through the seams:
    /// constructing one installs its event handler via the injected
    /// install call, so no hard-coded Carbon call hides in the paths the
    /// lifecycle tests drive.
    func testInitInstallsItsEventHandlerThroughTheSeam() {
        let service = makeService(layer: layer, store: store)

        XCTAssertEqual(layer.installs, 1,
            "the handler install goes through the injected seam")
        XCTAssertNotNil(service)
    }
}

/// A stand-in for the system-wide Carbon hotkey layer: it hands out
/// registrations and keeps the ledger of which combos are live, shared by
/// every service in a test so "nothing stays registered" and "a replacement
/// registers cleanly" are observable at the seam the real calls sit behind.
private final class FakeHotkeyLayer {
    struct Combo: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    struct Registration {
        let combo: Combo
        let hotKeyID: UInt32
        let ref: EventHotKeyRef
    }

    /// The ledger: every registration the layer currently holds.
    private(set) var live: [Registration] = []
    /// Every register call, refused ones included, in call order.
    private(set) var registerCalls: [(combo: Combo, hotKeyID: UInt32)] = []
    /// Every ref handed back through unregister.
    private(set) var unregistered: [EventHotKeyRef] = []
    /// How many handlers were installed through the install seam.
    private(set) var installs = 0
    /// Combos the layer refuses (owned by "another app").
    var refuseCombos: Set<Combo> = []
    private var mintedRefs = 0

    private let handlerRef = OpaquePointer(bitPattern: 0xBEEF)!

    func register(
        keyCode: UInt32, modifiers: UInt32, hotKeyID: UInt32,
        ref: inout EventHotKeyRef?
    ) -> OSStatus {
        let combo = Combo(keyCode: keyCode, modifiers: modifiers)
        registerCalls.append((combo, hotKeyID))
        guard !refuseCombos.contains(combo) else {
            return OSStatus(eventHotKeyExistsErr)
        }
        mintedRefs += 1
        let fresh = OpaquePointer(bitPattern: mintedRefs)!
        live.append(Registration(combo: combo, hotKeyID: hotKeyID, ref: fresh))
        ref = fresh
        return noErr
    }

    func unregister(_ ref: EventHotKeyRef) {
        unregistered.append(ref)
        live.removeAll { $0.ref == ref }
    }

    func install(userData: UnsafeMutableRawPointer, ref: inout EventHandlerRef?) {
        installs += 1
        ref = handlerRef
    }

    func remove(_ ref: EventHandlerRef) {}

    /// How many dispatches one press of `combo` produces. The layer
    /// delivers one event per live registration of a combo to the app's
    /// installed handler, so a combo registered twice — a dead service's
    /// phantom plus its replacement's — dispatches twice per press.
    func dispatchesPerPress(_ combo: Combo) -> Int {
        live.count { $0.combo == combo }
    }
}
