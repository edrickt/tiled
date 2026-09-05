import AppKit
import XCTest

@testable import tiled

/// The recorder's VoiceOver contract: each button names its slot (the row
/// label is a separate, unassociated static text) and exposes its binding
/// or recording state as the value — so the Shortcuts tab is seventeen
/// distinguishable controls, not seventeen anonymous buttons.
final class RecorderButtonAccessibilityTests: XCTestCase {
    func testInitLabelsTheSlot() {
        let button = RecorderButton(slot: .topLeft)
        XCTAssertEqual(button.accessibilityLabel(), "Top Left shortcut")
    }

    func testValueCarriesTheBinding() {
        let button = RecorderButton(slot: .topLeft)
        button.showBinding(HotkeyBinding(modifiers: 0, keyCode: 0)) // "0x00" label
        XCTAssertNotNil(button.accessibilityValue())
        button.showBinding(HotkeyBinding(modifiers: 0, keyCode: nil)) // disabled
        XCTAssertEqual(button.accessibilityValue() as? String, "disabled")
    }

    func testBeginRecordingMarksTheValueAsRecording() {
        let button = RecorderButton(slot: .leftHalf)
        button.beginRecording { _ in }
        XCTAssertEqual(button.accessibilityValue() as? String, "recording")
        button.showBinding(HotkeyBinding(modifiers: 0, keyCode: nil))
    }

    func testDisabledInitRendersDisabledValue() {
        let button = RecorderButton(slot: .sixthRight)
        XCTAssertEqual(button.accessibilityValue() as? String, "disabled")
    }
}

/// The failure HUD: shows feedback text on screen, replaces it on the next
/// outcome, and dismisses itself — so sighted keyboard users get the same
/// words VoiceOver users hear, at the moment of failure.
final class FeedbackHUDTests: XCTestCase {
    func testShowSetsCurrentText() {
        let hud = FeedbackHUD()
        hud.dismissDelay = 60 // never fires during the test
        hud.show("Safari couldn't be tiled")
        XCTAssertEqual(hud.currentText, "Safari couldn't be tiled")
        hud.hide()
        XCTAssertNil(hud.currentText)
    }

    func testShowReplacesTextInsteadOfStacking() {
        let hud = FeedbackHUD()
        hud.dismissDelay = 60
        hud.show("first")
        hud.show("second")
        XCTAssertEqual(hud.currentText, "second")
        hud.hide()
    }

    func testDismissTimerClearsCurrentText() {
        let expectation = self.expectation(description: "HUD auto-dismisses")
        let hud = FeedbackHUD()
        hud.dismissDelay = 0.05
        hud.show("brief")
        XCTAssertEqual(hud.currentText, "brief")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertNil(hud.currentText)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testStickyNoticeStaysUntilReplaced() {
        let hud = FeedbackHUD()
        hud.dismissDelay = 0.05
        // Destructive outcomes persist past the toast window: a 2.5s
        // toast is too small a window for "your workspace just moved."
        hud.show("Safari went back to where it was.", sticky: true, stickySeconds: 60)
        let expectation = self.expectation(description: "sticky HUD persists")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(hud.currentText, "Safari went back to where it was.")
            // The next outcome replaces, never stacks.
            hud.show("brief")
            XCTAssertEqual(hud.currentText, "brief")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        hud.hide()
    }

    func testStickyNoticeStillExpires() {
        // Reassurance that never leaves curdles into nagging: even
        // sticky notices expire — late, not never.
        let expectation = self.expectation(description: "sticky HUD expires")
        let hud = FeedbackHUD()
        hud.show("Safari went back to where it was.", sticky: true, stickySeconds: 0.05)
        XCTAssertEqual(hud.currentText, "Safari went back to where it was.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertNil(hud.currentText)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }
}


/// The Enable-all bulk path must never silently destroy combos recorded
/// while the section was disabled: a stale park loses to a fresh edit,
/// and the tab says which slots it kept. Drives the real bulk button
/// (identifier "bulk-quarters") so the test covers the same path the
/// user clicks — including the rebuild that swaps the button itself.
final class ShortcutsBulkEnableTests: XCTestCase {
    private func findButton(identifier: String, titledPrefix: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton,
           button.identifier?.rawValue == identifier,
           button.title.hasPrefix(titledPrefix)
        { return button }
        for subview in view.subviews {
            if let hit = findButton(identifier: identifier, titledPrefix: titledPrefix, in: subview) {
                return hit
            }
        }
        return nil
    }

    private func scrubParkKeys() {
        for slot in Slot.allCases {
            UserDefaults.standard.removeObject(forKey: "parkedHotkey.\(slot.rawValue)")
        }
    }

    func testEnableAllKeepsEditsMadeWhileDisabled() {
        scrubParkKeys()
        let store = HotkeyStore()
        let tab = ShortcutsTab(hotkeyStore: store)
        tab.onContentRebuilt = { _ in }
        var view = tab.build(size: NSSize(width: 440, height: 480), window: nil)

        // Disable the whole quarters section via its real bulk button.
        guard let disable = findButton(
            identifier: "bulk-quarters", titledPrefix: "Disable all", in: view)
        else { return XCTFail("expected a Disable-all bulk button") }
        disable.performClick(nil)

        // The click rebuilds content; grab the fresh view from the shell hook.
        var rebuilt: NSView?
        tab.onContentRebuilt = { rebuilt = $0 }
        // Re-click through the hook path: performClick already rebuilt, so
        // re-resolve the button from the rebuilt view the hook captured.
        // (performClick above rebuilt synchronously; capture it directly.)
        view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        _ = rebuilt
        XCTAssertEqual(
            store.binding(for: .topLeft).keyCode, nil,
            "section disabled: Top Left has no combo")

        // Record a fresh combo into the disabled slot (legitimate edit).
        let fresh = HotkeyBinding(modifiers: 0, keyCode: 6)
        XCTAssertEqual(store.apply(fresh, for: .topLeft), .applied)

        // Enable the section via its real bulk button.
        guard let enable = findButton(
            identifier: "bulk-quarters", titledPrefix: "Enable all", in: view)
        else { return XCTFail("expected an Enable-all bulk button after disabling") }
        enable.performClick(nil)

        XCTAssertEqual(
            store.binding(for: .topLeft), fresh,
            "the fresh edit wins over the stale park — no silent data loss")
        XCTAssertNil(
            UserDefaults.standard.dictionary(forKey: "parkedHotkey.topLeft"),
            "the stale park is dropped, not left to strike later")
        scrubParkKeys()
    }

    func testStaleParkDoesNotClobberWhenNothingWasEdited() {
        // The complement: with no post-disable edits, Enable all restores
        // the parked combos exactly (the pre-existing contract).
        scrubParkKeys()
        let store = HotkeyStore()
        let tab = ShortcutsTab(hotkeyStore: store)
        tab.onContentRebuilt = { _ in }
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let disable = findButton(
            identifier: "bulk-quarters", titledPrefix: "Disable all", in: view)
        else { return XCTFail("expected a Disable-all bulk button") }
        let before = store.binding(for: .topRight)
        disable.performClick(nil)
        XCTAssertEqual(store.binding(for: .topRight).keyCode, nil)

        let view2 = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        guard let enable = findButton(
            identifier: "bulk-quarters", titledPrefix: "Enable all", in: view2)
        else { return XCTFail("expected an Enable-all bulk button") }
        enable.performClick(nil)
        XCTAssertEqual(
            store.binding(for: .topRight), before,
            "unedited slots restore their parked combos verbatim")
        scrubParkKeys()
    }
}
