import AppKit
import Carbon.HIToolbox
import XCTest

@testable import tiled

/// The recorder's Carbon hand-off, driven through the real Shortcuts tab
/// and an injected registrar: arming any recorder retires every global
/// registration (a registered combo is consumed before the local
/// monitor), and every disarm path — Esc, silent tab-away, window close,
/// a reload, a tab rebuild — puts the same set back exactly once.
final class ShortcutsSuspensionTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: HotkeyStore!

    override func setUp() {
        super.setUp()
        suiteName = "ShortcutsSuspensionTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = HotkeyStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        suiteName = ""
        super.tearDown()
    }

    private func makeService(_ registrar: FakeHotkeyRegistrar) -> HotkeyService {
        HotkeyService(
            store: store, registrar: registrar, eventHandlerInstaller: { noErr })
    }

    private func makeTab(_ service: HotkeyService) -> ShortcutsTab {
        let tab = ShortcutsTab(hotkeyStore: store, defaults: defaults)
        tab.hotkeyServiceProvider = { service }
        tab.onContentRebuilt = { _ in }
        return tab
    }

    private func findRecorder(key: SlotKey, in view: NSView) -> RecorderButton? {
        if let button = view as? RecorderButton, button.hotkeyAction == .slotKey(key) {
            return button
        }
        for subview in view.subviews {
            if let hit = findRecorder(key: key, in: subview) { return hit }
        }
        return nil
    }

    private func keyDown(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode)!
    }

    /// The live registration the store hands the service on construction.
    private func defaultActions() -> Int {
        HotkeyAction.allCases.count
    }

    func testArmingARecorderSuspendsEveryRegistrationAndEscRestoresThem() {
        let registrar = FakeHotkeyRegistrar()
        let service = makeService(registrar)
        XCTAssertEqual(registrar.activeTokens.count, defaultActions())
        let tab = makeTab(service)
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let recorder = findRecorder(key: .topLeft, in: view)
        else { return XCTFail("expected a Top Left recorder") }

        recorder.performClick(nil)

        XCTAssertTrue(recorder.isRecording, "the click arms the recorder")
        XCTAssertTrue(service.isSuspended)
        XCTAssertTrue(
            registrar.activeTokens.isEmpty,
            "while armed, Carbon must hold no combo the recorder needs to see")
        XCTAssertEqual(registrar.requests.count, defaultActions(), "arming registers nothing")

        // Esc is the decisive cancel: the button disarms, the tab restores.
        XCTAssertNil(recorder.routeRecordedEvent(keyDown(keyCode: UInt16(kVK_Escape))))

        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(service.isSuspended)
        XCTAssertEqual(
            registrar.activeTokens.count, defaultActions(),
            "Esc restores every binding")
        XCTAssertEqual(
            registrar.requests.count, 2 * defaultActions(),
            "the resume pass runs exactly once")
    }

    func testRecordingAComboCurrentlyRegisteredCapturesItInsteadOfFiringTheAction() {
        // The audited failure: Carbon consumed the combo before the local
        // monitor, so the action fired behind Settings and the recorder
        // never saw the key. With every registration retired while armed,
        // the recorder receives Top Right's live combo, rejects it as a
        // duplicate, and keeps the old binding.
        let registrar = FakeHotkeyRegistrar()
        let service = makeService(registrar)
        let tab = makeTab(service)
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let recorder = findRecorder(key: .topLeft, in: view)
        else { return XCTFail("expected a Top Left recorder") }
        let old = store.binding(for: .topLeft)
        let owner = store.binding(for: .topRight)

        recorder.performClick(nil)
        XCTAssertTrue(
            registrar.activeTokens.isEmpty,
            "the recording window has no live Carbon registration to consume the key")

        _ = recorder.routeRecordedEvent(
            keyDown(
                keyCode: UInt16(owner.keyCode!),
                modifiers: [.option, .shift]))

        XCTAssertEqual(
            store.binding(for: .topLeft), old,
            "the duplicate is captured by the recorder and rejected, not dispatched")
        XCTAssertEqual(
            registrar.activeTokens.count, defaultActions(),
            "the disarm after the duplicate restores the registrations")
        XCTAssertEqual(
            store.binding(for: .topRight), owner,
            "the other action never fired: its registration was retired")
    }

    func testSilentCancelRestoresRegistrations() {
        let registrar = FakeHotkeyRegistrar()
        let service = makeService(registrar)
        let tab = makeTab(service)
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let recorder = findRecorder(key: .middleColumn, in: view)
        else { return XCTFail("expected a Middle Column recorder") }
        recorder.performClick(nil)
        XCTAssertTrue(registrar.activeTokens.isEmpty)

        // Tab-away/pass-through: the button disarms with no decision and
        // fires `onSilentCancel`; the tab restores the registrations.
        recorder.viewDidMoveToWindow()

        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(service.isSuspended)
        XCTAssertEqual(registrar.activeTokens.count, defaultActions())
    }

    func testWindowCloseRestoresRegistrations() {
        let registrar = FakeHotkeyRegistrar()
        let service = makeService(registrar)
        let tab = makeTab(service)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        let view = tab.build(size: NSSize(width: 440, height: 480), window: window)
        window.contentView = view
        guard let recorder = findRecorder(key: .bottomLeft, in: view)
        else { return XCTFail("expected a Bottom Left recorder") }
        recorder.performClick(nil)
        XCTAssertTrue(registrar.activeTokens.isEmpty)

        // The close button posts this same notification; the recorder's
        // window-close observer disarms silently and the tab resumes.
        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification, object: window)

        XCTAssertFalse(recorder.isRecording, "the close disarms the recorder")
        XCTAssertFalse(service.isSuspended)
        XCTAssertEqual(
            registrar.activeTokens.count, defaultActions(),
            "no registration stays retired after the window closes")
    }

    func testReloadAndTabRebuildRestoreRegistrations() {
        let registrar = FakeHotkeyRegistrar()
        let service = makeService(registrar)
        let tab = makeTab(service)
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let recorder = findRecorder(key: .topRight, in: view)
        else { return XCTFail("expected a Top Right recorder") }

        recorder.performClick(nil)
        XCTAssertTrue(registrar.activeTokens.isEmpty)
        tab.reload()

        XCTAssertFalse(recorder.isRecording, "a reload disarms the stale recorder")
        XCTAssertEqual(
            registrar.activeTokens.count, defaultActions(),
            "a reload never leaves the hotkeys suspended")

        recorder.performClick(nil)
        XCTAssertTrue(registrar.activeTokens.isEmpty)
        tab.reset()

        XCTAssertFalse(recorder.isRecording, "a tab rebuild disarms the stale recorder")
        XCTAssertFalse(service.isSuspended)
        XCTAssertEqual(
            registrar.activeTokens.count, defaultActions(),
            "a tab rebuild restores the registrations")
    }
}
