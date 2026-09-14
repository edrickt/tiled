import XCTest
@testable import tiled

/// The status menu's user-visible strings, extracted from AppDelegate:
/// pluralization, disabled labels, and hotkey-failure wording are
/// contracts with the user, pinned here.
final class MenuTextTests: XCTestCase {
    // MARK: Titles

    func testUndoDisplacementTitleSingularAndPlural() {
        XCTAssertEqual(MenuText.undoDisplacementTitle(evictedCount: 1), "Restore 1 Evicted Window")
        XCTAssertEqual(MenuText.undoDisplacementTitle(evictedCount: 2), "Restore 2 Evicted Windows")
    }

    func testUntileAllTitleSingularAndPlural() {
        XCTAssertEqual(MenuText.untileAllTitle(count: 1), "Untile 1 Window")
        XCTAssertEqual(MenuText.untileAllTitle(count: 3), "Untile 3 Windows")
    }

    func testExpandItemTitleWithAndWithoutLabel() {
        XCTAssertEqual(MenuText.expandItemTitle(label: "⌥⇧⏎"), "Expand to Fill Screen · ⌥⇧⏎")
        XCTAssertEqual(MenuText.expandItemTitle(label: nil), "Expand to Fill Screen")
    }

    func testExpandItemTitleNamesTheReturnSlotWhenExpanded() {
        // A toggle with no visible state leaves the user guessing: when a
        // window is expanded the row says where the toggle goes back.
        XCTAssertEqual(
            MenuText.expandItemTitle(label: "⌥⇧⏎", expandedSlot: .topLeft),
            "Return to Top Left · ⌥⇧⏎")
        XCTAssertEqual(
            MenuText.expandItemTitle(label: "⌥⇧⏎", expandedSlot: nil),
            "Expand to Fill Screen · ⌥⇧⏎")
    }

    func testEvictItemTitleWithAndWithoutLabel() {
        XCTAssertEqual(MenuText.evictItemTitle(label: "⌥⇧⌫"), "Evict Focused Window · ⌥⇧⌫")
        XCTAssertEqual(MenuText.evictItemTitle(label: nil), "Evict Focused Window")
    }

    func testEvictHotkeyWarningNamesComboAndRecovery() {
        XCTAssertEqual(
            MenuText.evictHotkeyWarning(),
            "The evict shortcut (⌥⇧⌫) could not be registered; "
                + "quit and reopen Tiled to try again.")
    }

    func testWarningSummaryTitleSingularAndPlural() {
        XCTAssertEqual(
            MenuText.warningSummaryTitle(count: 1),
            "⚠ 1 shortcut problem: a combo is taken")
        XCTAssertEqual(
            MenuText.warningSummaryTitle(count: 3),
            "⚠ 3 shortcut problems: combos are taken")
    }

    // MARK: Warnings

    func testSettingsHotkeyWarningNamesComboAndRecovery() {
        XCTAssertEqual(
            MenuText.settingsHotkeyWarning(),
            "The Settings shortcut (⌃⌥⇧⌘,) could not be registered; "
                + "quit and reopen Tiled to get back to Settings while hidden.")
    }

    func testHotkeyFailureWarningNamesLabelAndSlot() {
        XCTAssertEqual(
            MenuText.hotkeyFailureWarning(label: "⌥⇧U", slot: .topLeft),
            "⌥⇧U could not be registered; “Top Left” has no hotkey. "
                + "Another Tiled shortcut or a system shortcut may already use it.")
    }

    func testHotkeyFailureWarningFallsBackToSlotNameWithoutSelfContradiction() {
        XCTAssertEqual(
            MenuText.hotkeyFailureWarning(label: nil, slot: .sixthLeft),
            "The shortcut for “Left Third” could not be registered: it has no hotkey.")
    }

    func testUndoHotkeyWarningNamesComboAndMenuRecovery() {
        XCTAssertEqual(
            MenuText.undoHotkeyWarning(),
            "The undo shortcut (⌃⌥⇧⌘Z) could not be registered; "
                + "undo the last displacement from the Tiled menu instead.")
    }

    func testExpandHotkeyWarningNamesComboAndRecovery() {
        XCTAssertEqual(
            MenuText.expandHotkeyWarning(),
            "The expand shortcut (⌥⇧⏎) could not be registered; "
                + "quit and reopen Tiled to try again.")
    }

    // MARK: Menu rows

    func testWindowLineWithAndWithoutLabel() {
        XCTAssertEqual(
            MenuText.windowLine(slot: .leftHalf, appName: "Safari", label: "⌥⇧J"),
            "Left Half · Safari (⌥⇧J)")
        XCTAssertEqual(
            MenuText.windowLine(slot: .leftHalf, appName: "Safari", label: nil),
            "Left Half · Safari")
    }

    func testWindowLineFallbackAppName() {
        XCTAssertEqual(
            MenuText.windowLine(slot: .rightHalf, appName: nil, label: nil),
            "Right Half · window")
    }

    func testTileItemTitleWithAndWithoutLabel() {
        XCTAssertEqual(MenuText.tileItemTitle(slot: .topLeft, label: "⌥⇧U"), "Top Left · ⌥⇧U")
        XCTAssertEqual(MenuText.tileItemTitle(slot: .topLeft, label: nil), "Top Left")
    }

    // MARK: Feedback announcements

    func testAnnouncements() {
        XCTAssertEqual(
            MenuText.noFocusedWindowAnnouncement(),
            "No focused window: click a window first.")
        XCTAssertEqual(
            MenuText.nothingToUndoAnnouncement(),
            "Nothing to undo: a later change replaced it.")
        XCTAssertEqual(
            MenuText.alreadyTiledAnnouncement(slot: .topRight),
            "Top Right: already there.")
        XCTAssertEqual(
            MenuText.refusedAnnouncement(windowName: "Safari"),
            "Safari couldn't be tiled: the app refused to resize it.")
        XCTAssertEqual(
            MenuText.refusedAnnouncement(windowName: nil),
            "That window couldn't be tiled: the app refused to resize it.")
        XCTAssertEqual(
            MenuText.expandRefusedAnnouncement(windowName: "Safari"),
            "Safari couldn't be expanded: the app refused to resize it.")
        XCTAssertEqual(
            MenuText.expandRefusedAnnouncement(windowName: nil),
            "That window couldn't be expanded: the app refused to resize it.")
        XCTAssertEqual(
            MenuText.nothingToEvictAnnouncement(),
            "That window isn't tiled: nothing to evict.")
    }
}
