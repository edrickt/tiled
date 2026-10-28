import XCTest
@testable import tiled

/// Phase 2: app-level settings (menu-bar icon visibility). Launch-at-login
/// itself goes through SMAppService and isn't unit-testable; the persisted
/// flag is.
final class AppSettingsTests: XCTestCase {
    /// One suite per test, stable across accesses, removed afterwards:
    /// a computed property minted a fresh domain per read and leaked it.
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "tiledTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

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

    func testWelcomeShownByDefault() {
        let (settings, _) = makeSettings()
        XCTAssertFalse(settings.didDismissWelcome)
    }

    func testDismissWelcomePersists() {
        let (_, defaults) = makeSettings()
        AppSettings(defaults: defaults).didDismissWelcome = true
        XCTAssertTrue(AppSettings(defaults: defaults).didDismissWelcome)
    }

    func testWelcomeDismissalPersistsAndOnlyGatesTheFirstLaunch() {
        // The flag's own semantics: default un-dismissed, dismissal
        // persists. The reopen path (`showWelcomeAgain`) ignores the flag
        // and is pinned in WelcomeLifecycleTests, not here.
        let (_, defaults) = makeSettings()
        XCTAssertFalse(AppSettings(defaults: defaults).didDismissWelcome)
        AppSettings(defaults: defaults).didDismissWelcome = true
        XCTAssertTrue(AppSettings(defaults: defaults).didDismissWelcome)

        XCTAssertFalse(
            AppLaunchPlan.make(
                isTrusted: true, didDismissWelcome: true, hideMenuBarIcon: false
            ).showsWelcome,
            "a dismissed guide does not reopen on the next launch")
    }
}
