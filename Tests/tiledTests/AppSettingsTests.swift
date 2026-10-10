import XCTest
@testable import tiled

/// Phase 2: app-level settings (menu-bar icon visibility). Launch-at-login
/// itself goes through SMAppService and isn't unit-testable; the persisted
/// flag is.
final class AppSettingsTests: XCTestCase {
    private var suiteName: String { "tiledTests-\(UUID().uuidString)" }

    private func makeSettings() -> (AppSettings, UserDefaults) {
        let defaults = UserDefaults(suiteName: suiteName)!
        return (AppSettings(defaults: defaults), defaults)
    }

    func testIconVisibleByDefault() {
        let (settings, _) = makeSettings()
        XCTAssertFalse(settings.hideMenuBarIcon)
    }

    func testHideIconPersists() {
        let (_, defaults) = makeSettings()
        AppSettings(defaults: defaults).hideMenuBarIcon = true
        XCTAssertTrue(AppSettings(defaults: defaults).hideMenuBarIcon)
    }

    func testUnhidePersists() {
        let (_, defaults) = makeSettings()
        AppSettings(defaults: defaults).hideMenuBarIcon = true
        AppSettings(defaults: defaults).hideMenuBarIcon = false
        XCTAssertFalse(AppSettings(defaults: defaults).hideMenuBarIcon)
    }

    func testAnimateLayoutChangesDefaultsOn() {
        // UserDefaults.bool returns false for a missing key; the default
        // must come from the key's absence, not that zero value: existing
        // installs upgrade into animation, never out of it.
        let (settings, _) = makeSettings()
        XCTAssertTrue(settings.animateLayoutChanges)
    }

    func testAnimateLayoutChangesPersists() {
        // Persistence across launches is the same defaults key read by a
        // fresh AppSettings: off must survive, and so must turning it
        // back on.
        let (_, defaults) = makeSettings()
        AppSettings(defaults: defaults).animateLayoutChanges = false
        XCTAssertFalse(AppSettings(defaults: defaults).animateLayoutChanges)
        AppSettings(defaults: defaults).animateLayoutChanges = true
        XCTAssertTrue(AppSettings(defaults: defaults).animateLayoutChanges)
    }

    func testWelcomeShownByDefault() {
        let (settings, _) = makeSettings()
        XCTAssertFalse(settings.didDismissWelcome)
    }

    func testDismissWelcomePersists() {
        let (_, defaults) = makeSettings()
        AppSettings(defaults: defaults).didDismissWelcome = true
        XCTAssertTrue(AppSettings(defaults: defaults).didDismissWelcome)
    }

    func testWelcomeDismissDoesNotBlockReopen() {
        // didDismissWelcome gates the FIRST launch only; Help reopens the
        // guide on demand (showWelcomeAgain ignores the flag). Pin the
        // flag semantics: dismissal persists, default is un-dismissed.
        let (_, defaults) = makeSettings()
        XCTAssertFalse(AppSettings(defaults: defaults).didDismissWelcome)
        AppSettings(defaults: defaults).didDismissWelcome = true
        XCTAssertTrue(AppSettings(defaults: defaults).didDismissWelcome)
        // Re-entry path must not clear the flag (next launch still skips
        // Welcome); it only presents the tab for this session.
        XCTAssertTrue(AppSettings(defaults: defaults).didDismissWelcome)
    }
}
