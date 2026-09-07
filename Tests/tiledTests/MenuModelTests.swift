import Carbon.HIToolbox
import XCTest
@testable import tiled

/// The status menu's structure contracts, pinned on the platform-free
/// `MenuModel`: warning precedence over the status line, slot grouping in
/// the tile submenu, the window rows' three-action submenus, undo
/// visibility, the untrusted block, and the always-present app section.
/// `AppDelegate` maps these items onto NSMenu one-for-one.
final class MenuModelTests: XCTestCase {
    private func snapshot(
        isTrusted: Bool = true,
        warnings: [String] = [],
        notice: String? = nil,
        layoutTitle: String = "Quarters",
        activeLayout: LayoutKind = .quarters,
        tileError: String? = nil,
        hasHotkeyWarnings: Bool = false,
        hasFocusedWindow: Bool = true,
        hasSplitterBackup: Bool = false,
        expandedSlot: Slot? = nil,
        tiledWindows: [MenuModel.Snapshot.TiledWindow] = [],
        canUndoDisplacement: Bool = false,
        evictedCount: Int = 0
    ) -> MenuModel.Snapshot {
        MenuModel.Snapshot(
            isTrusted: isTrusted,
            warnings: warnings,
            notice: notice,
            layoutTitle: layoutTitle,
            activeLayout: activeLayout,
            tileError: tileError,
            hasHotkeyWarnings: hasHotkeyWarnings,
            hasSplitterBackup: hasSplitterBackup,
            hasFocusedWindow: hasFocusedWindow,
            expandedSlot: expandedSlot,
            tiledWindows: tiledWindows,
            canUndoDisplacement: canUndoDisplacement,
            evictedCount: evictedCount)
    }

    private var defaultBinding = HotkeyStore.defaultBinding(for: .topLeft)
    private func items(_ snap: MenuModel.Snapshot) -> [MenuModel.Item] {
        MenuModel.items(snapshot: snap) { [self] slot in
            slot == .topLeft ? defaultBinding : HotkeyStore.defaultBinding(for: slot)
        }
    }

    private func tileSubmenu(_ model: [MenuModel.Item]) -> MenuModel.Item? {
        model.first { $0.title == "Tile Focused Window" }
    }

    // MARK: Status block

    func testWarningsCollapseToOneSummaryRow() {
        let model = items(snapshot(
            warnings: ["⌥⇧U is already used by another app"],
            notice: "Switched to Sixths · 1 window untiled.",
            hasHotkeyWarnings: true))
        // One summary row, not one row per warning: the menu's first
        // screenful is the everyday surface, not a troubleshooting essay.
        XCTAssertEqual(model.first?.title, "⚠ 1 shortcut problem — other apps own it")
        XCTAssertFalse(model.first!.isEnabled)
        // The compass survives trouble: the summary rides above the status line.
        XCTAssertTrue(
            model.contains { $0.title == "Layout: Quarters · 0 tiled" },
            "warnings never erase the layout/count line")
        // The latest outcome narrates even while warnings persist: a
        // lingering hotkey failure must not erase the record of what the
        // workspace just did. Warnings diagnose; the notice narrates.
        XCTAssertTrue(
            model.contains { $0.title == "Switched to Sixths · 1 window untiled." },
            "notices render below warnings, never suppressed by them")
    }

    func testTileErrorRendersVerbatimNeverAsAShortcutProblem() {
        // A tiling refusal is NOT a shortcut problem: it renders verbatim
        // as its own row, never squashed under the shortcut summary.
        let refused = items(snapshot(tileError: "Safari couldn't be tiled"))
        XCTAssertEqual(refused.first?.title, "Safari couldn't be tiled")
        XCTAssertFalse(refused.first!.isEnabled)
        XCTAssertFalse(refused.contains { $0.action == .openShortcuts })

        // Both kinds at once: two failure kinds, two rows, each named.
        let model = items(snapshot(
            warnings: ["⌥⇧U is already used by another app"],
            tileError: "Safari couldn't be tiled",
            hasHotkeyWarnings: true))
        XCTAssertEqual(model[0].title, "Safari couldn't be tiled")
        XCTAssertEqual(model[1].title, "⚠ 1 shortcut problem — other apps own it")
        XCTAssertEqual(model[2].title, "Open Shortcuts…")
    }

    func testWarningSummaryCounts() {
        XCTAssertEqual(
            MenuText.warningSummaryTitle(count: 1),
            "⚠ 1 shortcut problem — other apps own it")
        XCTAssertEqual(
            MenuText.warningSummaryTitle(count: 3),
            "⚠ 3 shortcut problems — other apps own them")
    }

    func testExpandRowReflectsExpandedState() {
        // Stateless toggle: the row reads the same expanded or not.
        let plain = items(snapshot())
        XCTAssertEqual(
            plain.first { $0.action == .toggleExpand }?.title,
            "Expand to Fill Screen — ⌥⇧⏎")
        // Stateful toggle: with an expanded focused window the row says
        // where the toggle goes back — no guessing what it does now.
        let expanded = items(snapshot(expandedSlot: .leftHalf))
        XCTAssertEqual(
            expanded.first { $0.action == .toggleExpand }?.title,
            "Return to Left Half — ⌥⇧⏎")
    }

    func testHotkeyWarningsGrowAnOpenShortcutsRow() {
        let model = items(snapshot(
            warnings: ["⌥⇧U is already used by another app — “Top Left” has no hotkey."],
            hasHotkeyWarnings: true))
        let warnings = model.prefix(2).map(\.title)
        XCTAssertEqual(warnings[0], "⚠ 1 shortcut problem — other apps own it")
        // A disabled row can't fix itself: the actionable row follows,
        // opening exactly the tab that can rebind it.
        XCTAssertEqual(warnings[1], "Open Shortcuts…")
        XCTAssertEqual(model[1].action, .openShortcuts)
        XCTAssertTrue(model[1].isEnabled)
    }

    func testCollapsedWarningsKeepSingleRowForMany() {
        let model = items(snapshot(warnings: ["a", "b", "c"]))
        XCTAssertEqual(model.prefix(1).map(\.title), ["⚠ 3 shortcut problems — other apps own them"])
        XCTAssertTrue(model.prefix(1).allSatisfy { !$0.isEnabled })
    }

    func testNoticeAndStatusLineWhenTrusted() {
        let model = items(snapshot(
            notice: "Undid layout switch · 1 window restored.", layoutTitle: "Sixths"))
        XCTAssertEqual(model[0].title, "Undid layout switch · 1 window restored.")
        XCTAssertFalse(model[0].isEnabled)
        XCTAssertEqual(model[1].title, "Layout: Sixths · 0 tiled")
        XCTAssertFalse(model[1].isEnabled)
    }

    func testNoStatusRowsWhenUntrusted() {
        let model = items(snapshot(isTrusted: false))
        XCTAssertFalse(model.contains { $0.title.hasPrefix("Layout:") })
    }

    // MARK: Tile submenu

    func testTileSubmenuListsOnlyTheActiveLayoutPlusASwitchRow() {
        // Quarters on screen: quads + halves + one row to Sixths.
        let quarters = tileSubmenu(items(snapshot(activeLayout: .quarters)))!
        let qChildren = quarters.children!
        let qHeaders = qChildren.filter(\.isHeader).map(\.title)
        XCTAssertEqual(qHeaders, ["Quarters — Quads", "Halves"])
        let qSlots = qChildren.compactMap {
            if case .tileSlot(let slot)? = $0.action { return slot }
            return nil
        }
        XCTAssertEqual(qSlots, SlotPresentation.quartersQuads + SlotPresentation.quartersHalves)
        let qSwitch = qChildren.first { $0.action == .switchToSixths }
        XCTAssertEqual(qSwitch?.title, "Switch to Sixths (focused window → Top Left Sixth)")
        XCTAssertTrue(qSwitch?.isEnabled == true, "focused window in the test harness")

        // No focused window: the switch row disables and states its
        // precondition instead of no-op-ing on click.
        let unfocused = items(snapshot(activeLayout: .quarters, hasFocusedWindow: false))
        let uTile = tileSubmenu(unfocused)!
        let uSwitch = uTile.children!.first { $0.action == .switchToSixths }
        XCTAssertEqual(uSwitch?.isEnabled, false)
        XCTAssertEqual(
            uSwitch?.disabledReason, "Needs a focused window — click a window first.")

        // Sixths on screen: corners + thirds + two-thirds + one row back.
        let sixths = tileSubmenu(items(snapshot(activeLayout: .sixths)))!
        let sChildren = sixths.children!
        let sHeaders = sChildren.filter(\.isHeader).map(\.title)
        XCTAssertEqual(sHeaders, ["Sixths — Corners", "Thirds", "Two-Thirds"])
        let sSlots = sChildren.compactMap {
            if case .tileSlot(let slot)? = $0.action { return slot }
            return nil
        }
        XCTAssertEqual(
            sSlots,
            SlotPresentation.sixthsCorners
                + SlotPresentation.sixthsThirds
                + SlotPresentation.sixthsTwoThirds)
        let sSwitch = sChildren.first { $0.action == .switchToQuarters }
        XCTAssertEqual(sSwitch?.title, "Switch to Quarters (focused window → Top Left)")
    }

    // MARK: Expand item

    func testExpandItemSitsBetweenTileSubmenuAndWindowRows() {
        let model = items(snapshot(tiledWindows: [
            .init(id: 1, slot: .topLeft, appName: "Safari"),
        ]))
        let expandIndex = model.firstIndex { $0.action == .toggleExpand }
        XCTAssertNotNil(expandIndex)
        XCTAssertEqual(model[expandIndex!].title, "Expand to Fill Screen — ⌥⇧⏎")
        let tileIndex = model.firstIndex { $0.title == "Tile Focused Window" }!
        XCTAssertEqual(expandIndex, tileIndex + 1, "the expand row follows the tile submenu")
    }

    func testExpandItemHiddenWhenUntrusted() {
        XCTAssertFalse(items(snapshot(isTrusted: false)).contains { $0.action == .toggleExpand })
    }

    func testEvictItemSitsAfterExpandRow() {
        let model = items(snapshot(tiledWindows: [
            .init(id: 1, slot: .topLeft, appName: "Safari"),
        ]))
        let evictIndex = model.firstIndex { $0.action == .evictFocusedWindow }
        XCTAssertNotNil(evictIndex)
        XCTAssertEqual(model[evictIndex!].title, "Evict Focused Window — ⌥⇧⌫")
        let expandIndex = model.firstIndex { $0.action == .toggleExpand }!
        XCTAssertEqual(evictIndex, expandIndex + 1, "the evict row follows the expand row")
    }

    func testEvictItemHiddenWhenUntrusted() {
        XCTAssertFalse(items(snapshot(isTrusted: false)).contains { $0.action == .evictFocusedWindow })
    }

    /// The tile submenu lists the active layout only, so the custom-label
    /// test forces sixths (the disabled slot under test is a sixth).
    func testTileItemsCarryLiveLabelsFromTheStore() {
        let model = MenuModel.items(snapshot: snapshot(activeLayout: .sixths)) { slot in
            switch slot {
            case .sixthTopLeft:
                return HotkeyBinding(modifiers: UInt32(optionKey), keyCode: UInt32(kVK_ANSI_Q))
            case .sixthRight:
                return HotkeyBinding(modifiers: 0, keyCode: nil) // disabled slot
            default:
                return HotkeyStore.defaultBinding(for: slot)
            }
        }
        let tile = model.first { $0.title == "Tile Focused Window" }!
        let topLeft = tile.children!.first { $0.title.contains("Top Left Sixth") }!
        XCTAssertEqual(topLeft.title, "Top Left Sixth — ⌥Q")
        XCTAssertEqual(topLeft.action, .tileSlot(.sixthTopLeft))
        // A disabled slot (nil label) still renders, without a combo.
        let disabled = tile.children!.first { $0.title.contains("Right Third") }!
        XCTAssertEqual(disabled.title, "Right Third")
    }

    // MARK: Manage section

    func testTiledWindowRowsHaveThreeActionSubmenus() {
        let model = items(snapshot(tiledWindows: [
            .init(id: 7, slot: .leftHalf, appName: "Safari"),
        ]))
        let row = model.first { $0.title.contains("Left Half") }!
        XCTAssertEqual(row.title, "Left Half — Safari (⌥⇧J)")
        XCTAssertEqual(row.action, nil, "the row itself doesn't act")
        XCTAssertEqual(row.children?.map(\.title), [
            "Untile This Window", "Focus Safari", "Tile Focused Window Here",
        ])
        XCTAssertEqual(row.children?.map(\.action), [
            .untileWindow(7), .focusWindow(7), .tileHere(.leftHalf),
        ])
    }

    func testWindowRowFallbackAppName() {
        let model = items(snapshot(tiledWindows: [
            .init(id: 3, slot: .sixthRight, appName: nil),
        ]))
        XCTAssertEqual(model.first { $0.title.contains("Right Third") }?.children?
            .first { $0.title.hasPrefix("Focus") }?.title, "Focus Window")
    }

    func testUndoItemOnlyWhenAvailableWithPluralTitle() {
        let withUndo = items(snapshot(
            tiledWindows: [
                .init(id: 1, slot: .topLeft, appName: nil),
                .init(id: 2, slot: .topRight, appName: nil),
            ],
            canUndoDisplacement: true, evictedCount: 2))
        let undo = withUndo.first { $0.action == .undoSwitch }
        XCTAssertEqual(undo?.title, "Restore 2 Evicted Windows — \u{2303}\u{2325}\u{21E7}\u{2318}Z")
        XCTAssertEqual(undo?.keyEquivalent, "", "the true combo lives in the title, not a ⌘Z glyph")

        let withoutUndo = items(snapshot(
            tiledWindows: [.init(id: 1, slot: .topLeft, appName: nil)],
            canUndoDisplacement: false))
        XCTAssertFalse(withoutUndo.contains { $0.action == .undoSwitch })
        // Bulk actions still exist without undo.
        XCTAssertTrue(withoutUndo.contains { $0.action == .untileAll })
        XCTAssertTrue(withoutUndo.contains { $0.action == .resetDividers })
        let reset = withoutUndo.first { $0.action == .resetDividers }
        XCTAssertEqual(reset?.title, "Reset Splitters")
    }

    func testSplitterBackupFlipsTheManageRow() {
        let plain = items(snapshot(tiledWindows: [
            .init(id: 1, slot: .topLeft, appName: nil),
        ]))
        XCTAssertEqual(
            plain.first { $0.action == .resetDividers }?.title, "Reset Splitters")
        let backedUp = items(snapshot(
            hasSplitterBackup: true,
            tiledWindows: [.init(id: 1, slot: .topLeft, appName: nil)]))
        // One destructive action, one receipt: the row becomes its own undo.
        XCTAssertEqual(
            backedUp.first { $0.action == .resetDividers }?.title,
            "Restore Previous Splitters")
    }

    func testMultiMonitorWindowsGroupUnderDisplayHeaders() {
        // Two displays tiled: the manage list groups per display under
        // a disabled header per section, in controller order.
        var snap = snapshot(tiledWindows: [
            .init(id: 1, slot: .topLeft, appName: "Safari", screenName: "Display 1"),
            .init(id: 2, slot: .topLeft, appName: "Mail", screenName: "Display 2"),
        ])
        snap.monitorSections = [
            .init(title: "Display 1 — Quarters · 1 tiled", key: "Display 1"),
            .init(title: "Display 2 — Sixths · 1 tiled", key: "Display 2"),
        ]
        let model = items(snap)
        let headers = model.filter(\.isHeader).map(\.title)
        XCTAssertTrue(headers.contains("Display 1 — Quarters · 1 tiled"))
        XCTAssertTrue(headers.contains("Display 2 — Sixths · 1 tiled"))
        // Rows follow their header in order: Safari under Display 1,
        // Mail under Display 2.
        let titles = model.map(\.title)
        let first = titles.firstIndex(of: "Display 1 — Quarters · 1 tiled")!
        let second = titles.firstIndex(of: "Display 2 — Sixths · 1 tiled")!
        XCTAssertTrue(titles[first + 1].contains("Safari"))
        XCTAssertTrue(titles[second + 1].contains("Mail"))
    }

    func testSingleMonitorKeepsTheFlatList() {
        // No sections (legacy snapshot): no display headers, just rows.
        let model = items(snapshot(tiledWindows: [
            .init(id: 1, slot: .topLeft, appName: "Safari"),
        ]))
        XCTAssertFalse(model.contains { $0.isHeader && $0.title.contains("Display") })
        XCTAssertTrue(model.contains { $0.title.contains("Safari") })
    }

    func testOrphanRowWithMismatchedSectionKeyStillRenders() {
        // Defensive tail: a stale snapshot can carry a window whose
        // screenName matches no section header. The row must still
        // render (trailing, after the matched sections) — silently
        // dropping a user's window from the manage list is the one
        // failure this branch exists to prevent.
        var snap = snapshot(tiledWindows: [
            .init(id: 1, slot: .topLeft, appName: "Safari", screenName: "Display 1"),
            .init(id: 2, slot: .sixthTopLeft, appName: "Orphan", screenName: "Display 2"),
        ])
        snap.monitorSections = [
            .init(title: "Display 1 — Quarters · 1 tiled", key: "Display 1"),
        ]
        let model = items(snap)

        let titles = model.map(\.title)
        XCTAssertTrue(
            titles.contains { $0.contains("Orphan") },
            "the mismatched window must not vanish from the manage list")
        // It renders after the matched section, not under a header that
        // does not describe it.
        let headerIndex = titles.firstIndex(of: "Display 1 — Quarters · 1 tiled")!
        let safariIndex = titles.firstIndex { $0.contains("Safari") }!
        let orphanIndex = titles.firstIndex { $0.contains("Orphan") }!
        XCTAssertEqual(safariIndex, headerIndex + 1)
        XCTAssertGreaterThan(orphanIndex, safariIndex)
    }

    func testEmptySpaceHasNoWindowListOrBulkActions() {
        let model = items(snapshot())
        XCTAssertFalse(model.contains { $0.action == .untileAll })
        XCTAssertFalse(model.contains { $0.action == .undoSwitch })
        XCTAssertFalse(model.contains { $0.action == .resetDividers })
        // But the tile submenu stays: hotkeys still work on an empty space.
        XCTAssertNotNil(tileSubmenu(model))
    }

    // MARK: Untrusted + app section

    func testUntrustedMenuShowsWaitingAndSettingsEscapeHatch() {
        let model = items(snapshot(isTrusted: false))
        let waiting = model.first { $0.title == "Waiting for Accessibility permission…" }
        XCTAssertEqual(waiting?.isEnabled, false)
        XCTAssertEqual(
            model.first { $0.action == .openAccessibilitySettings }?.title,
            "Open System Settings")
        XCTAssertNil(tileSubmenu(model), "no tiling actions while untrusted")
    }

    func testAppSectionAlwaysPresentLast() {
        for snap in [snapshot(), snapshot(isTrusted: false), snapshot(warnings: ["x"])] {
            let model = items(snap)
            XCTAssertEqual(
                model.suffix(3).map(\.title), ["Tiled Guide", "Settings…", "Quit Tiled"])
            XCTAssertEqual(model.last?.keyEquivalent, "q")
            XCTAssertEqual(model.first { $0.action == .showSettings }?.keyEquivalent, ",")
        }
    }
}
