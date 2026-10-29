import ApplicationServices
import XCTest

@testable import tiled

/// Which app element answers the focused-window read, extracted as a
/// pure decision so the fallback is testable without an Accessibility
/// grant.
///
/// Regression context, Spotify (a Chromium/CEF app): it never exposes a
/// focused UI element — `app.FocusedUIElement` answers
/// `.noValue` (-25212) and its window's `AXFocused` stays false while
/// only `AXMain` is true. With no focused element to name, the
/// system-wide element answers `.noValue` for
/// `kAXFocusedApplicationAttribute`, so every slot key resolved "no
/// focused window" and Spotify could not be tiled at all. Verified live
/// on macOS 26 (Tiled 0.3.0, `TILED_DEBUG=1`): the system-wide read
/// logged err=-25212 with Spotify frontmost and err=0 with Firefox
/// frontmost, milliseconds apart; the app element's own
/// `kAXFocusedWindowAttribute` read answered `.success` for Spotify the
/// whole time, which is the read the fallback takes. The workspace's
/// frontmost app is the equivalent of the missing answer, the same way
/// `tools/repro/window-lifecycle-repro.swift` already resolves it.
final class AXFocusFallbackTests: XCTestCase {
    func testAnAnsweringSystemWideReadIsUsedAsIs() {
        // The fallback covers a *missing* answer, never a real one: a
        // system-wide read that names the app is authoritative even when
        // the workspace's frontmost app disagrees (the two can race an
        // app switch).
        XCTAssertEqual(
            LiveWindowGateway.focusSource(systemWideRead: .success, frontmost: 4321),
            .systemWide)
        XCTAssertEqual(
            LiveWindowGateway.focusSource(systemWideRead: .success, frontmost: nil),
            .systemWide)
    }

    func testNoValueFallsBackToTheWorkspaceFrontmostApp() {
        // The measured Spotify failure: the system-wide element has no
        // focused application to name.
        XCTAssertEqual(
            LiveWindowGateway.focusSource(systemWideRead: .noValue, frontmost: 16952),
            .frontmost(16952))
    }

    func testCannotCompleteFallsBackToo() {
        // The same missing answer, spelled as the timeout/cannotComplete
        // a busy or secure-input-blocked frontmost app produces.
        XCTAssertEqual(
            LiveWindowGateway.focusSource(systemWideRead: .cannotComplete, frontmost: 16952),
            .frontmost(16952))
        XCTAssertEqual(
            LiveWindowGateway.focusSource(systemWideRead: .apiDisabled, frontmost: 7),
            .frontmost(7))
    }

    func testNoFrontmostAppLeavesNothingToTile() {
        // The fallback needs an app to ask. With no frontmost app (or a
        // pid AX can never own) there is no requester, and the receipt
        // says so instead of naming an app.
        XCTAssertEqual(
            LiveWindowGateway.focusSource(systemWideRead: .noValue, frontmost: nil), .none)
        XCTAssertEqual(
            LiveWindowGateway.focusSource(systemWideRead: .noValue, frontmost: 0), .none)
        XCTAssertEqual(
            LiveWindowGateway.focusSource(systemWideRead: .noValue, frontmost: -1), .none)
    }

    func testTheFallbackStillFailsWhenTheAppHasNoFocusedWindow() {
        // Falling back is not a promise: the app-level read decides, and
        // an app with no focused window is still nothing to tile.
        XCTAssertEqual(
            LiveWindowGateway.focusSource(systemWideRead: .noValue, frontmost: 99),
            .frontmost(99))
    }
}
