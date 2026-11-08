import AppKit
import XCTest

@testable import tiled

/// A resize after the Shortcuts tab was built must reach the tab's next
/// collapse/bulk rebuild. The shell is the window's delegate and hands the
/// tab the live content size, so the rebuilt rows are laid out for the
/// window the user is actually looking at.
final class SettingsShortcutsRebuildTests: XCTestCase {
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsShortcutsRebuildTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    private func temporaryDefaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    private func tabView(in view: NSView) -> NSTabView? {
        if let tabs = view as? NSTabView, tabs.selectedTabViewItem != nil { return tabs }
        for subview in view.subviews {
            if let hit = tabView(in: subview) { return hit }
        }
        return nil
    }

    private func findButton(identifier: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.identifier?.rawValue == identifier {
            return button
        }
        for subview in view.subviews {
            if let hit = findButton(identifier: identifier, in: subview) { return hit }
        }
        return nil
    }

    func testCollapseRebuildAfterAResizeUsesTheNewContentSize() throws {
        let defaults = temporaryDefaults()
        let controller = SettingsWindowController(
            settings: AppSettings(defaults: defaults),
            hotkeyStore: HotkeyStore(defaults: defaults))
        defer { controller.close() }
        // Capture the size the tab built for *before* the shell installs
        // the view: AppKit then resizes the installed view to the tab's
        // content rect, which would mask a stale build size.
        var rebuiltSize: NSSize?
        controller.onShortcutsRebuilt = { rebuiltSize = $0.frame.size }
        controller.show(selecting: .shortcuts)

        let window = try XCTUnwrap(controller.window)
        let resized = NSSize(width: 620, height: 520)
        window.setContentSize(resized)
        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(content.bounds.size, resized, "precondition: the resize landed")

        let tabs = try XCTUnwrap(tabView(in: content))
        let view = try XCTUnwrap(tabs.selectedTabViewItem?.view)
        let header = try XCTUnwrap(findButton(identifier: "appActions", in: view))
        header.performClick(nil)

        XCTAssertEqual(
            try XCTUnwrap(rebuiltSize), resized,
            "the rebuilt Shortcuts content must use the live window size, not the build-time one")
    }
}
