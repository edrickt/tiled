import AppKit
import XCTest

@testable import tiled

/// The General tab's "Animate layout changes" checkbox: the visible
/// control behind `AppSettings.animateLayoutChanges`. It must reflect the
/// stored setting on show and write the setting back on click; the
/// controller reads the setting per move, so neither needs a refresh or
/// a relaunch.
final class SettingsAnimationToggleTests: XCTestCase {
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // A fresh suite per run: a fixed suite name persists on disk and
        // leaks state (and stale preferences) between runs.
        suiteName = "SettingsAnimationToggleTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    private func temporaryDefaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    private func findCheckbox(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for subview in view.subviews {
            if let hit = findCheckbox(titled: title, in: subview) { return hit }
        }
        return nil
    }

    func testCheckboxReflectsTheStoredSetting() {
        let settings = AppSettings(defaults: temporaryDefaults())
        let tab = GeneralTab(settings: settings)
        let view = tab.build(size: NSSize(width: 440, height: 480))
        tab.loadValues()

        let checkbox = findCheckbox(titled: "Animate layout changes", in: view)
        XCTAssertNotNil(checkbox, "General must carry the animation toggle.")
        XCTAssertEqual(checkbox?.state, .on, "on by default")

        settings.animateLayoutChanges = false
        tab.loadValues()
        XCTAssertEqual(
            checkbox?.state, .off,
            "showing the tab reflects the stored setting, not the build-time default")
    }

    func testClickingTheCheckboxWritesTheSetting() {
        let defaults = temporaryDefaults()
        let settings = AppSettings(defaults: defaults)
        let tab = GeneralTab(settings: settings)
        let view = tab.build(size: NSSize(width: 440, height: 480))
        tab.loadValues()
        guard let checkbox = findCheckbox(titled: "Animate layout changes", in: view) else {
            return XCTFail("General must carry the animation toggle.")
        }
        XCTAssertEqual(checkbox.state, .on, "on by default")

        checkbox.performClick(nil)

        XCTAssertEqual(checkbox.state, .off, "the click flips the control")
        XCTAssertFalse(settings.animateLayoutChanges, "the click writes the setting")
        XCTAssertFalse(
            AppSettings(defaults: defaults).animateLayoutChanges,
            "the setting persists for the next launch")

        checkbox.performClick(nil)

        XCTAssertEqual(checkbox.state, .on)
        XCTAssertTrue(settings.animateLayoutChanges, "clicking back on writes on")
        XCTAssertTrue(AppSettings(defaults: defaults).animateLayoutChanges)
    }
}
