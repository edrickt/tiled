import AppKit
import XCTest

@testable import tiled

/// The Shortcuts live region's one message model: registration failures
/// outrank a recorder conflict, which outranks an action result, and a
/// reload that recomputes the same failure must not speak it again.
final class ShortcutNoticeTests: XCTestCase {
    private func label(containing text: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.stringValue.contains(text) {
            return field
        }
        for subview in view.subviews {
            if let hit = label(containing: text, in: subview) { return hit }
        }
        return nil
    }

    func testNoticeKeepsFailuresThenConflictThenResult() {
        let notice = ShortcutNotice(
            failures: ["first failure", "second failure"],
            conflict: "already used",
            result: "kept the edit")

        XCTAssertEqual(
            notice?.entries.map(\.kind),
            [.failure, .failure, .conflict, .result])
        XCTAssertEqual(
            notice?.text,
            "first failure\nsecond failure\nalready used\nkept the edit",
            "the live region has one fixed order regardless of which writer fired")
    }

    func testEmptyNoticeIsNilSoClearingIsSilent() {
        XCTAssertNil(ShortcutNotice())
        XCTAssertNil(ShortcutNotice(failures: [""], conflict: "", result: ""))
    }

    func testReloadAnnouncesAPersistentFailureOnlyWhenItsIdentityChanges() {
        let suite = "ShortcutNoticeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HotkeyStore(defaults: defaults)
        let tab = ShortcutsTab(hotkeyStore: store, defaults: defaults)
        var announcements: [String] = []
        tab.onAnnouncement = { announcements.append($0) }
        tab.failedActionsProvider = { [.expand] }
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)

        tab.reload()
        XCTAssertEqual(announcements.count, 1, "the first readable failure is announced")
        XCTAssertTrue(announcements[0].contains("could not be registered"))
        XCTAssertNotNil(label(containing: "could not be registered", in: view))

        tab.reload()
        XCTAssertEqual(
            announcements.count, 1,
            "a reload that recomputes the same failure is not a new identity")
        XCTAssertNotNil(label(containing: "could not be registered", in: view))

        tab.failedActionsProvider = { [] }
        tab.reload()
        XCTAssertEqual(announcements.count, 1, "clearing the line is silent")
        XCTAssertNil(label(containing: "could not be registered", in: view))

        tab.failedActionsProvider = { [.expand] }
        tab.reload()
        XCTAssertEqual(
            announcements.count, 2,
            "the same text returning after a clear is a new identity")
    }
}
