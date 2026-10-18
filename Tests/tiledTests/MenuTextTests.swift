import XCTest
@testable import tiled

/// The status menu's user-visible strings, extracted from AppDelegate:
/// pluralization, disabled labels, and hotkey-failure wording are
/// contracts with the user, pinned here.
final class MenuTextTests: XCTestCase {
    // MARK: Titles

    func testUndoDisplacementTitleSingularAndPlural() {
        XCTAssertEqual(
            MenuText.undoDisplacementTitle(displacedCount: 1),
            "Restore 1 Displaced Window")
        XCTAssertEqual(
            MenuText.undoDisplacementTitle(displacedCount: 2),
            "Restore 2 Displaced Windows")
    }

    func testUntileAllTitleSingularAndPlural() {
        XCTAssertEqual(MenuText.untileAllTitle(count: 1), "Untile 1 Window")
        XCTAssertEqual(MenuText.untileAllTitle(count: 3), "Untile 3 Windows")
    }

    func testExpandItemTitleWithAndWithoutLabel() {
        XCTAssertEqual(
            MenuText.expandItemTitle(label: "⌥⇧⏎", expandState: .expands),
            "Expand to Fill Screen · ⌥⇧⏎")
        XCTAssertEqual(
            MenuText.expandItemTitle(label: nil, expandState: .expands),
            "Expand to Fill Screen")
    }

    func testExpandItemTitleNamesWhereAnExpandedWindowReturns() {
        // A toggle with no visible state leaves the user guessing: when a
        // window is expanded the row says where the toggle goes back.
        XCTAssertEqual(
            MenuText.expandItemTitle(label: "⌥⇧⏎", expandState: .returnsToSlot(.topLeft)),
            "Return to Top Left · ⌥⇧⏎")
        // An expanded untiled window has no slot to name: the row names
        // its previous frame instead of pretending the next press expands.
        XCTAssertEqual(
            MenuText.expandItemTitle(label: "⌥⇧⏎", expandState: .returnsToPreviousFrame),
            "Return to Previous Frame · ⌥⇧⏎")
        XCTAssertEqual(
            MenuText.expandItemTitle(label: nil, expandState: .returnsToPreviousFrame),
            "Return to Previous Frame")
        XCTAssertEqual(
            MenuText.expandItemTitle(label: "⌥⇧⏎", expandState: .expands),
            "Expand to Fill Screen · ⌥⇧⏎")
    }

    func testEvictItemTitleWithAndWithoutLabel() {
        XCTAssertEqual(MenuText.evictItemTitle(label: "⌥⇧⌫"), "Evict Focused Window · ⌥⇧⌫")
        XCTAssertEqual(MenuText.evictItemTitle(label: nil), "Evict Focused Window")
    }

    func testHotkeyFailureWarningNamesActionRecovery() {
        // App actions carry their own recovery advice, so the sentence
        // names the action and the way back.
        XCTAssertEqual(
            MenuText.hotkeyFailureWarning(
                label: "⌥⇧⌫", title: "Evict Focused Window",
                recovery: "quit and reopen Tiled to try again."),
            "The Evict Focused Window shortcut (⌥⇧⌫) could not be registered; "
                + "quit and reopen Tiled to try again.")
        XCTAssertEqual(
            MenuText.hotkeyFailureWarning(
                label: "⌃⌥⇧⌘,", title: "Open Settings",
                recovery: "quit and reopen Tiled to get back to Settings while hidden."),
            "The Open Settings shortcut (⌃⌥⇧⌘,) could not be registered; "
                + "quit and reopen Tiled to get back to Settings while hidden.")
        XCTAssertEqual(
            MenuText.hotkeyFailureWarning(
                label: "⌃⌥⇧⌘Z", title: "Undo Last Displacement",
                recovery: "undo the last displacement from the Tiled menu instead."),
            "The Undo Last Displacement shortcut (⌃⌥⇧⌘Z) could not be registered; "
                + "undo the last displacement from the Tiled menu instead.")
        XCTAssertEqual(
            MenuText.hotkeyFailureWarning(
                label: "⌥⇧R", title: "Reset Splitters",
                recovery: "reset splitters from the Tiled menu instead."),
            "The Reset Splitters shortcut (⌥⇧R) could not be registered; "
                + "reset splitters from the Tiled menu instead.")
        XCTAssertEqual(
            MenuText.hotkeyFailureWarning(
                label: "⌥⇧⏎", title: "Expand to Fill Screen",
                recovery: "quit and reopen Tiled to try again."),
            "The Expand to Fill Screen shortcut (⌥⇧⏎) could not be registered; "
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

    func testHotkeyFailureWarningNamesLabelAndSlot() {
        XCTAssertEqual(
            MenuText.hotkeyFailureWarning(label: "⌥⇧U", title: "Top Left"),
            "⌥⇧U could not be registered; “Top Left” has no hotkey. "
                + "Another Tiled shortcut or a system shortcut may already use it.")
    }

    func testHotkeyFailureWarningFallsBackToActionNameWithoutSelfContradiction() {
        XCTAssertEqual(
            MenuText.hotkeyFailureWarning(label: nil, title: "Left Third"),
            "The shortcut for “Left Third” could not be registered: it has no hotkey.")
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
        XCTAssertEqual(
            MenuText.deferredOffSpaceAnnouncement(),
            "That Space isn't visible yet: the change will apply when you return to it.")
    }

    // MARK: Action receipt announcements

    func testEvictAnnouncement() {
        XCTAssertEqual(MenuText.evictedAnnouncement(), "Focused window evicted.")
    }

    func testUntileAllAnnouncements() {
        XCTAssertEqual(MenuText.untileAllAnnouncement(), "All tiled windows restored.")
        XCTAssertEqual(
            MenuText.nothingToUntileAnnouncement(), "No tiled windows on this canvas.")
    }

    func testUntileWindowAnnouncements() {
        XCTAssertEqual(
            MenuText.untileWindowAnnouncement(windowName: "Safari"), "Safari untiled.")
        XCTAssertEqual(MenuText.untileWindowAnnouncement(windowName: nil), "Window untiled.")
        XCTAssertEqual(
            MenuText.nothingToUntileWindowAnnouncement(),
            "That window isn't tiled: nothing to untile.")
    }

    func testUndoAnnouncement() {
        XCTAssertEqual(MenuText.undoAnnouncement(), "Displaced windows restored.")
    }

    func testUntileWindowRefusalAnnouncementNamesTheBackgroundDisplay() {
        let error = "Couldn't restore “Safari”: it may still be sitting in its old tile."
        XCTAssertEqual(
            MenuText.untileWindowRefusalAnnouncement(
                displayName: "Display 2", error: error),
            "Display 2: " + error)
        XCTAssertEqual(
            MenuText.untileWindowRefusalAnnouncement(displayName: nil, error: error),
            error,
            "a single display adds no name: it would distinguish nothing")
    }
}
