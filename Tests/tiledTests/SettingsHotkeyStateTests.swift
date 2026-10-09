import Carbon.HIToolbox
import XCTest

@testable import tiled

/// The hide-icon recovery narration, decided from the Open Settings
/// shortcut's live state. Hiding the icon destroys the only visible
/// handle on the app, so the confirm and the standing hint must promise
/// the recovery that actually works: the current binding's real combo
/// when it is live, relaunch-only otherwise — never the factory combo
/// hard-coded, never a phantom "taken by another app" for a shortcut
/// that is merely not registered yet.
final class SettingsHotkeyStateTests: XCTestCase {
    /// A rebound Open Settings combo: ⌘K, not the factory ⌃⌥⇧⌘,.
    private let rebound = HotkeyBinding(
        modifiers: UInt32(cmdKey), keyCode: UInt32(kVK_ANSI_K))
    private let disabled = HotkeyBinding(modifiers: 0, keyCode: nil)
    private let factoryCombo = "⌃⌥⇧⌘,"

    // MARK: Fact → state decision

    func testRegisteredBindingIsLiveWithItsRealLabel() {
        let state = SettingsHotkeyState.current(
            binding: rebound, registration: .registered)
        XCTAssertEqual(state, .live(label: "⌘K"))
    }

    func testDisabledBindingIsDisabledEvenThoughNothingFailed() {
        // Disabled ≠ failed: a disabled action registers nothing and
        // warns about nothing, so the old "not in failedActions" probe
        // read it as registered and the confirm hard-promised a combo
        // that does not exist.
        let state = SettingsHotkeyState.current(
            binding: disabled, registration: .registered)
        XCTAssertEqual(state, .disabled)
    }

    func testNotStartedRegistrationIsPendingPermissionNotAConflict() {
        // Pre-trust the registration pass never runs: nothing is
        // registered yet and the pending permission — not another
        // app — is the reason.
        let state = SettingsHotkeyState.current(
            binding: rebound, registration: .notStarted)
        XCTAssertEqual(state, .pendingPermission)
    }

    func testRefusedRegistrationIsLostWithItsRealLabel() {
        let state = SettingsHotkeyState.current(
            binding: rebound, registration: .refused)
        XCTAssertEqual(state, .registrationLost(label: "⌘K"))
    }

    // MARK: Confirm copy

    func testConfirmNamesTheReboundCombo() {
        let state = SettingsHotkeyState.current(
            binding: rebound, registration: .registered)
        XCTAssertTrue(
            state.confirmRecovery.contains("press ⌘K anywhere"),
            "the confirm must name the combo as currently bound, got: \(state.confirmRecovery)")
        XCTAssertFalse(
            state.confirmRecovery.contains(factoryCombo),
            "the confirm must not promise the factory combo after a rebind, got: \(state.confirmRecovery)")
    }

    func testConfirmOffersRelaunchOnlyAndSaysSoWhenTheShortcutIsDisabled() {
        // With Open Settings disabled there is no combo at all: the
        // confirm offers the relaunch-only recovery and says that it is
        // the only way back — and must not name any combo as a way back.
        let state = SettingsHotkeyState.current(
            binding: disabled, registration: .registered)
        XCTAssertTrue(
            state.confirmRecovery.contains("quit and reopen Tiled"),
            "the confirm must offer the relaunch recovery, got: \(state.confirmRecovery)")
        XCTAssertTrue(
            state.confirmRecovery.contains("turned off"),
            "the confirm must say the shortcut is off, got: \(state.confirmRecovery)")
        XCTAssertTrue(
            state.confirmRecovery.contains("only way back"),
            "the confirm must say relaunching is the only way back, got: \(state.confirmRecovery)")
        XCTAssertFalse(
            state.confirmRecovery.contains("press"),
            "the confirm must not name a combo when none is bound, got: \(state.confirmRecovery)")
    }

    func testConfirmNamesPendingPermissionNotAPhantomConflict() {
        // Pre-trust nothing is registered yet: the old probe read that
        // as "taken by another app" — a phantom conflict. The confirm
        // must name the pending-permission situation instead.
        let state = SettingsHotkeyState.current(
            binding: rebound, registration: .notStarted)
        XCTAssertTrue(
            state.confirmRecovery.contains("Accessibility permission"),
            "the confirm must name the pending permission, got: \(state.confirmRecovery)")
        XCTAssertTrue(
            state.confirmRecovery.contains("pending"),
            "the confirm must say the permission is pending, got: \(state.confirmRecovery)")
        XCTAssertFalse(
            state.confirmRecovery.contains("already used by another app"),
            "nothing registered yet is not a conflict, got: \(state.confirmRecovery)")
    }

    func testConfirmNamesTheRealLabelWhenRegistrationWasLost() {
        // A real conflict is diagnosed as one — with the label the
        // binding actually carries, never the factory combo.
        let state = SettingsHotkeyState.current(
            binding: rebound, registration: .refused)
        XCTAssertTrue(
            state.confirmRecovery.contains("⌘K"),
            "the confirm must name the rebound combo, got: \(state.confirmRecovery)")
        XCTAssertTrue(
            state.confirmRecovery.contains("already used by another app"),
            "the confirm must diagnose the real conflict, got: \(state.confirmRecovery)")
        XCTAssertFalse(
            state.confirmRecovery.contains(factoryCombo),
            "the confirm must not fall back to the factory combo, got: \(state.confirmRecovery)")
    }

    // MARK: Standing copy

    func testStandingSurfacesPromiseNoComboWhenNoneIsBound() {
        // Every non-live state: the hint and tooltip promise the
        // relaunch recovery only. The old hint hard-coded the factory
        // combo no matter what the binding said.
        for state in [
            SettingsHotkeyState.current(binding: disabled, registration: .registered),
            SettingsHotkeyState.current(binding: rebound, registration: .notStarted),
            SettingsHotkeyState.current(binding: rebound, registration: .refused),
        ] {
            XCTAssertTrue(
                state.hint.contains("quit and reopen Tiled"),
                "the hint must promise the relaunch recovery, got: \(state.hint)")
            XCTAssertFalse(
                state.hint.contains("press"),
                "the hint must not promise a combo that will not fire, got: \(state.hint)")
            XCTAssertFalse(
                state.hint.contains(factoryCombo),
                "the hint must not hard-code the factory combo, got: \(state.hint)")
            XCTAssertFalse(
                state.toolTip.contains("press"),
                "the tooltip must not promise a combo that will not fire, got: \(state.toolTip)")
            XCTAssertFalse(
                state.toolTip.contains(factoryCombo),
                "the tooltip must not hard-code the factory combo, got: \(state.toolTip)")
        }
    }

    func testStandingHintRendersTheCurrentBindingLabel() {
        let state = SettingsHotkeyState.current(
            binding: rebound, registration: .registered)
        XCTAssertTrue(
            state.hint.contains("press ⌘K anywhere"),
            "the hint must render the current binding's real label, got: \(state.hint)")
        XCTAssertFalse(
            state.hint.contains(factoryCombo),
            "the hint must not hard-code the factory combo, got: \(state.hint)")
    }
}
