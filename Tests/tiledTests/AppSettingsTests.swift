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
}
