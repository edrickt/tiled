import XCTest
@testable import tiled

/// The status menu's user-visible strings, extracted from AppDelegate:
/// pluralization, disabled labels, and hotkey-failure wording are
/// contracts with the user, pinned here.
final class MenuTextTests: XCTestCase {
    // MARK: Titles

    func testUndoSwitchTitleSingularAndPlural() {
        XCTAssertEqual(MenuText.undoSwitchTitle(evictedCount: 1), "Restore 1 Evicted Window")
        XCTAssertEqual(MenuText.undoSwitchTitle(evictedCount: 2), "Restore 2 Evicted Windows")
    }

    func testUntileAllTitleSingularAndPlural() {
        XCTAssertEqual(MenuText.untileAllTitle(count: 1), "Untile 1 Window")
        XCTAssertEqual(MenuText.untileAllTitle(count: 3), "Untile All 3 Windows")
    }

    func testExpandItemTitleWithAndWithoutLabel() {
        XCTAssertEqual(MenuText.expandItemTitle(label: "⌥⇧⏎"), "Expand to Fill Screen — ⌥⇧⏎")
        XCTAssertEqual(MenuText.expandItemTitle(label: nil), "Expand to Fill Screen")
    }

    // MARK: Warnings

    func testSettingsHotkeyWarningNamesComboAndRecovery() {
        XCTAssertEqual(
            MenuText.settingsHotkeyWarning(),
            "The Settings shortcut (⌃⌥⇧⌘,) is already used by another app — "
                + "relaunch tiled to get back to Settings while hidden.")
    }

    func testHotkeyFailureWarningNamesLabelAndSlot() {
        XCTAssertEqual(
            MenuText.hotkeyFailureWarning(label: "⌥⇧U", slot: .topLeft),
            "⌥⇧U is already used by another app — “Top Left” has no hotkey.")
    }

    func testHotkeyFailureWarningFallsBackToDisabled() {
        XCTAssertEqual(
            MenuText.hotkeyFailureWarning(label: nil, slot: .sixthLeft),
            "Disabled is already used by another app — “Left Third” has no hotkey.")
    }

    func testExpandHotkeyWarningNamesComboAndRecovery() {
        XCTAssertEqual(
            MenuText.expandHotkeyWarning(),
            "The expand shortcut (⌥⇧⏎) is already used by another app — "
                + "relaunch tiled to try registering it again.")
    }

    // MARK: Menu rows

    func testWindowLineWithAndWithoutLabel() {
        XCTAssertEqual(
            MenuText.windowLine(slot: .leftHalf, appName: "Safari", label: "⌥⇧J"),
            "Left Half — Safari (⌥⇧J)")
        XCTAssertEqual(
            MenuText.windowLine(slot: .leftHalf, appName: "Safari", label: nil),
            "Left Half — Safari")
    }

    func testWindowLineFallbackAppName() {
        XCTAssertEqual(
            MenuText.windowLine(slot: .rightHalf, appName: nil, label: nil),
            "Right Half — window")
    }

    func testTileItemTitleWithAndWithoutLabel() {
        XCTAssertEqual(MenuText.tileItemTitle(slot: .topLeft, label: "⌥⇧U"), "Top Left — ⌥⇧U")
        XCTAssertEqual(MenuText.tileItemTitle(slot: .topLeft, label: nil), "Top Left")
    }

    // MARK: Feedback announcements

    func testAnnouncements() {
        XCTAssertEqual(
            MenuText.noFocusedWindowAnnouncement(),
            "No focused window — click a window first.")
        XCTAssertEqual(
            MenuText.alreadyTiledAnnouncement(slot: .topRight),
            "Top Right — already there.")
        XCTAssertEqual(
            MenuText.refusedAnnouncement(windowName: "Safari"),
            "Safari couldn't be tiled — the app refused to resize it.")
        XCTAssertEqual(
            MenuText.refusedAnnouncement(windowName: nil),
            "That window couldn't be tiled — the app refused to resize it.")
        XCTAssertEqual(
            MenuText.expandRefusedAnnouncement(windowName: "Safari"),
            "Safari couldn't be expanded — the app refused to resize it.")
        XCTAssertEqual(
            MenuText.expandRefusedAnnouncement(windowName: nil),
            "That window couldn't be expanded — the app refused to resize it.")
    }
}
