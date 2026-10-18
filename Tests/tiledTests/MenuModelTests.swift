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
        expandState: ExpandToggleState = .expands,
        tiledWindows: [MenuModel.Snapshot.TiledWindow] = [],
        canUndoDisplacement: Bool = false,
        evictedCount: Int = 0,
        untileCount: Int = 0
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
            expandState: expandState,
            tiledWindows: tiledWindows,
            canUndoDisplacement: canUndoDisplacement,
            evictedCount: evictedCount,
            untileCount: untileCount)
    }

    private var defaultBinding = HotkeyStore.defaultBinding(for: .topLeft)
    private func items(_ snap: MenuModel.Snapshot) -> [MenuModel.Item] {
        MenuModel.items(snapshot: snap) { [self] action in
            action == .slot(.topLeft) ? defaultBinding : action.defaultBinding
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
        XCTAssertEqual(model.first?.title, "⚠ 1 shortcut problem: a combo is taken")
        XCTAssertFalse(model.first!.isEnabled)
        // The compass survives trouble: the summary rides above the status line.
        XCTAssertTrue(
            model.contains { $0.title == "Quarters" },
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
        XCTAssertEqual(model[1].title, "⚠ 1 shortcut problem: a combo is taken")
        XCTAssertEqual(model[2].title, "Open Shortcuts…")
    }

    func testWarningSummaryCounts() {
        XCTAssertEqual(
            MenuText.warningSummaryTitle(count: 1),
            "⚠ 1 shortcut problem: a combo is taken")
        XCTAssertEqual(
            MenuText.warningSummaryTitle(count: 3),
            "⚠ 3 shortcut problems: combos are taken")
    }

    func testExpandRowReflectsExpandedState() {
        // Not expanded: the row promises the expand.
        let plain = items(snapshot())
        XCTAssertEqual(
            plain.first { $0.action == .toggleExpand }?.title,
            "Expand to Fill Screen · ⌥⇧⏎")
        // Expanded and still tiled: the row says where the toggle goes
        // back: no guessing what it does now.
        let tiled = items(snapshot(expandState: .returnsToSlot(.leftHalf)))
        XCTAssertEqual(
            tiled.first { $0.action == .toggleExpand }?.title,
            "Return to Left Half · ⌥⇧⏎")
        // Expanded and untiled: there is no slot to name, so the row
        // names the previous frame instead of "Expand to Fill Screen"
        // (which would promise the press expands again).
        let untiled = items(snapshot(expandState: .returnsToPreviousFrame))
        XCTAssertEqual(
            untiled.first { $0.action == .toggleExpand }?.title,
            "Return to Previous Frame · ⌥⇧⏎")
    }

    func testHotkeyWarningsGrowAnOpenShortcutsRow() {
        let model = items(snapshot(
            warnings: ["⌥⇧U is already used by another app; “Top Left” has no hotkey."],
            hasHotkeyWarnings: true))
        let warnings = model.prefix(2).map(\.title)
        XCTAssertEqual(warnings[0], "⚠ 1 shortcut problem: a combo is taken")
        // A disabled row can't fix itself: the actionable row follows,
        // opening exactly the tab that can rebind it.
        XCTAssertEqual(warnings[1], "Open Shortcuts…")
        XCTAssertEqual(model[1].action, .openShortcuts)
        XCTAssertTrue(model[1].isEnabled)
    }

    func testCollapsedWarningsKeepSingleRowForMany() {
        let model = items(snapshot(warnings: ["a", "b", "c"]))
        XCTAssertEqual(model.prefix(1).map(\.title), ["⚠ 3 shortcut problems: combos are taken"])
        XCTAssertTrue(model.prefix(1).allSatisfy { !$0.isEnabled })
    }

    func testNoticeAndStatusLineWhenTrusted() {
        let model = items(snapshot(
            notice: "Undid layout switch · 1 window restored.", layoutTitle: "Sixths"))
        XCTAssertEqual(model[0].title, "Undid layout switch · 1 window restored.")
        XCTAssertFalse(model[0].isEnabled)
        XCTAssertEqual(model[1].title, "Sixths")
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
        XCTAssertEqual(qHeaders, ["Quarters · Quads", "Halves"])
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
            uSwitch?.disabledReason, "Needs a focused window: click a window first.")

        // Sixths on screen: corners + thirds + two-thirds + one row back.
        let sixths = tileSubmenu(items(snapshot(activeLayout: .sixths)))!
        let sChildren = sixths.children!
        let sHeaders = sChildren.filter(\.isHeader).map(\.title)
        XCTAssertEqual(sHeaders, ["Sixths · Corners", "Thirds", "Two-Thirds"])
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
        XCTAssertEqual(model[expandIndex!].title, "Expand to Fill Screen · ⌥⇧⏎")
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
        XCTAssertEqual(model[evictIndex!].title, "Evict Focused Window · ⌥⇧⌫")
        let expandIndex = model.firstIndex { $0.action == .toggleExpand }!
        XCTAssertEqual(evictIndex, expandIndex + 1, "the evict row follows the expand row")
    }

    func testEvictItemHiddenWhenUntrusted() {
        XCTAssertFalse(items(snapshot(isTrusted: false)).contains { $0.action == .evictFocusedWindow })
    }

    /// The tile submenu lists the active layout only, so the custom-label
    /// test forces sixths (the disabled slot under test is a sixth).
    func testTileItemsCarryLiveLabelsFromTheStore() {
        let model = MenuModel.items(snapshot: snapshot(activeLayout: .sixths)) { action in
            switch action {
            case .slot(.sixthTopLeft):
                return HotkeyBinding(modifiers: UInt32(optionKey), keyCode: UInt32(kVK_ANSI_Q))
            case .slot(.sixthRight):
                return HotkeyBinding(modifiers: 0, keyCode: nil) // disabled slot
            default:
                return action.defaultBinding
            }
        }
        let tile = model.first { $0.title == "Tile Focused Window" }!
        let topLeft = tile.children!.first { $0.title.contains("Top Left Sixth") }!
        XCTAssertEqual(topLeft.title, "Top Left Sixth · ⌥Q")
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
        XCTAssertEqual(row.title, "Left Half · Safari (⌥⇧⌘J)")
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
        XCTAssertEqual(undo?.title, "Restore 2 Evicted Windows · \u{2303}\u{2325}\u{21E7}\u{2318}Z")
        XCTAssertEqual(undo?.keyEquivalent, "", "the true combo lives in the title, not a ⌘Z glyph")

        let withoutUndo = items(snapshot(
            tiledWindows: [.init(id: 1, slot: .topLeft, appName: nil)],
            canUndoDisplacement: false,
            untileCount: 1))
        XCTAssertFalse(withoutUndo.contains { $0.action == .undoSwitch })
        // Bulk actions still exist without undo.
        XCTAssertTrue(withoutUndo.contains { $0.action == .untileAll })
        XCTAssertTrue(withoutUndo.contains { $0.action == .resetDividers })
        let reset = withoutUndo.first { $0.action == .resetDividers }
        XCTAssertEqual(reset?.title, "Reset Splitters · ⌥⇧R")
    }

    func testEmptyFocusedCanvasOmitsUntileAndResetRows() {
        // The manage list spans every visible canvas, but the focused
        // canvas's rows act on it alone. With the focused canvas empty and
        // another display tiled, the other display's window row still
        // renders while Untile and Reset Splitters stay out of the menu:
        // "Untile 0 Windows" would promise an action the click cannot take.
        let other = ScreenID(rawValue: 1)
        let model = items(snapshot(
            tiledWindows: [
                .init(id: 1, slot: .topLeft, appName: "Safari", screen: other),
            ],
            canUndoDisplacement: false,
            untileCount: 0))
        XCTAssertTrue(
            model.contains { $0.title.contains("Top Left · Safari") },
            "the aggregate window list still names windows on another display")
        XCTAssertFalse(model.contains { $0.action == .untileAll })
        XCTAssertFalse(model.contains { $0.action == .resetDividers })
        XCTAssertFalse(model.contains { $0.title.contains("Untile 0 Windows") })
    }

    func testUndoRowRendersWithoutTiledWindowsWhenTheChapterIsLive() {
        // Untile All leaves the focused canvas with no tiled windows but a
        // live undo chapter. The undo row is the menu's promise that the
        // hotkey still works; it must survive the empty window list.
        let model = items(snapshot(
            tiledWindows: [],
            canUndoDisplacement: true,
            evictedCount: 2,
            untileCount: 0))
        let undo = model.first { $0.action == .undoSwitch }
        XCTAssertEqual(
            undo?.title, "Restore 2 Evicted Windows · \u{2303}\u{2325}\u{21E7}\u{2318}Z")
        XCTAssertFalse(model.contains { $0.action == .untileAll })
        XCTAssertFalse(model.contains { $0.action == .resetDividers })
    }

    func testResetSplittersRowAdvertisesTheGlobalCombo() {
        // ⌥⇧R is a global hotkey: like the undo row, the combo lives in
        // the title text, not a key equivalent that only works with the
        // menu open.
        let row = items(snapshot(
            tiledWindows: [.init(id: 1, slot: .topLeft, appName: nil)],
            untileCount: 1)).first { $0.action == .resetDividers }
        XCTAssertEqual(row?.title, "Reset Splitters · ⌥⇧R")
        XCTAssertEqual(row?.keyEquivalent, "")
    }

    func testUntileAllTitleCountsTheFocusedCanvasOnly() {
        // Three windows across two canvases: the row acts on one canvas,
        // so its count must be that canvas's count, not the manage list's.
        let model = items(snapshot(
            tiledWindows: [
                .init(id: 1, slot: .topLeft, appName: nil),
                .init(id: 2, slot: .topRight, appName: nil),
                .init(id: 3, slot: .topLeft, appName: nil, screen: ScreenID(rawValue: 1)),
            ],
            untileCount: 2))
        let row = model.first { $0.action == .untileAll }
        XCTAssertEqual(row?.title, "Untile 2 Windows")
        // The focused canvas has windows, so its splitter row stays too.
        XCTAssertNotNil(model.first { $0.action == .resetDividers })
    }

    func testSplitterBackupFlipsTheManageRow() {
        let plain = items(snapshot(
            tiledWindows: [.init(id: 1, slot: .topLeft, appName: nil)],
            untileCount: 1))
        XCTAssertEqual(
            plain.first { $0.action == .resetDividers }?.title, "Reset Splitters · ⌥⇧R")
        let backedUp = items(snapshot(
            hasSplitterBackup: true,
            tiledWindows: [.init(id: 1, slot: .topLeft, appName: nil)],
            untileCount: 1))
        // One destructive action, one receipt: the row becomes its own undo.
        XCTAssertEqual(
            backedUp.first { $0.action == .resetDividers }?.title,
            "Restore Previous Splitters · ⌥⇧R")
    }

    func testRestoreSplittersRowSurvivesAnEmptyFocusedCanvas() {
        // A parked backup describes the focused canvas's splitters and is
        // a live one-step receipt: Untile All leaves it parked, so the
        // restore row stays reachable even with no tiled windows, exactly
        // as the undo row does. The Reset form still needs a tiled edge,
        // so it is absent on an empty canvas (see the test above).
        let model = items(snapshot(
            hasSplitterBackup: true,
            tiledWindows: [
                .init(id: 1, slot: .topLeft, appName: nil, screen: ScreenID(rawValue: 1)),
            ],
            untileCount: 0))
        XCTAssertEqual(
            model.first { $0.action == .resetDividers }?.title,
            "Restore Previous Splitters · ⌥⇧R")
        XCTAssertFalse(model.contains { $0.action == .untileAll })
    }

    func testMultiMonitorWindowsGroupUnderDisplayHeaders() {
        // Two displays tiled: the manage list groups per display under
        // a disabled header per section, in controller order.
        let left = ScreenID(rawValue: 0)
        let right = ScreenID(rawValue: 1)
        var snap = snapshot(tiledWindows: [
            .init(id: 1, slot: .topLeft, appName: "Safari", screen: left),
            .init(id: 2, slot: .topLeft, appName: "Mail", screen: right),
        ])
        snap.monitorSections = [
            .init(title: "Display 1 · Quarters · 1 tiled", key: left),
            .init(title: "Display 2 · Sixths · 1 tiled", key: right),
        ]
        let model = items(snap)
        let headers = model.filter(\.isHeader).map(\.title)
        XCTAssertTrue(headers.contains("Display 1 · Quarters · 1 tiled"))
        XCTAssertTrue(headers.contains("Display 2 · Sixths · 1 tiled"))
        // Rows follow their header in order: Safari under Display 1,
        // Mail under Display 2.
        let titles = model.map(\.title)
        let first = titles.firstIndex(of: "Display 1 · Quarters · 1 tiled")!
        let second = titles.firstIndex(of: "Display 2 · Sixths · 1 tiled")!
        XCTAssertTrue(titles[first + 1].contains("Safari"))
        XCTAssertTrue(titles[second + 1].contains("Mail"))
    }

    func testSectionsWithTheSameTitleMatchRowsByDisplayIdentity() {
        // Two unlabeled displays both render a "Display" header. The rows
        // must follow their own section's identity, never the first
        // header whose text matches: matching by name would pile both
        // windows under the first header and leave the second empty.
        let left = ScreenID(rawValue: 0)
        let right = ScreenID(rawValue: 1)
        var snap = snapshot(tiledWindows: [
            .init(id: 1, slot: .topLeft, appName: "Safari", screen: left),
            .init(id: 2, slot: .topLeft, appName: "Mail", screen: right),
        ])
        snap.monitorSections = [
            .init(title: "Display · Quarters · 1 tiled", key: left),
            .init(title: "Display · Quarters · 1 tiled", key: right),
        ]
        let model = items(snap)
        let titles = model.map(\.title)
        let headerIndices = titles.indices.filter { titles[$0] == "Display · Quarters · 1 tiled" }
        XCTAssertEqual(headerIndices.count, 2, "both identical Display headers render")
        let safariIndex = titles.firstIndex { $0.contains("Safari") }!
        let mailIndex = titles.firstIndex { $0.contains("Mail") }!
        XCTAssertLessThan(safariIndex, headerIndices[1],
                          "Safari belongs to the first display's section")
        XCTAssertLessThan(headerIndices[1], mailIndex,
                          "Mail belongs under the second display's own header")
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
        // screen matches no section key. The row must still render
        // (trailing, after the matched sections), silently dropping a
        // user's window from the manage list is the one failure this
        // branch exists to prevent.
        let orphanScreen = ScreenID(rawValue: 1)
        var snap = snapshot(tiledWindows: [
            .init(id: 1, slot: .topLeft, appName: "Safari", screen: ScreenID(rawValue: 0)),
            .init(id: 2, slot: .sixthTopLeft, appName: "Orphan", screen: orphanScreen),
        ])
        snap.monitorSections = [
            .init(title: "Display 1 · Quarters · 1 tiled", key: ScreenID(rawValue: 0)),
        ]
        let model = items(snap)

        let titles = model.map(\.title)
        XCTAssertTrue(
            titles.contains { $0.contains("Orphan") },
            "the mismatched window must not vanish from the manage list")
        // It renders after the matched section, not under a header that
        // does not describe it.
        let headerIndex = titles.firstIndex(of: "Display 1 · Quarters · 1 tiled")!
        let safariIndex = titles.firstIndex { $0.contains("Safari") }!
        let orphanIndex = titles.firstIndex { $0.contains("Orphan") }!
        XCTAssertEqual(safariIndex, headerIndex + 1)
        XCTAssertGreaterThan(orphanIndex, safariIndex)
    }

    func testEmptySpaceHasNoWindowListOrFocusedCanvasActions() {
        let model = items(snapshot())
        XCTAssertFalse(model.contains { $0.action == .untileAll })
        XCTAssertFalse(model.contains { $0.action == .undoSwitch })
        XCTAssertFalse(model.contains { $0.action == .resetDividers })
        // But the tile submenu stays: hotkeys still work on an empty space.
        XCTAssertNotNil(tileSubmenu(model))
    }

    func testManageSeparatorsNeverDoubleUp() {
        // Each manage shape ends cleanly: no separator at the menu's edges
        // and no adjacent pair, whether the block holds window rows,
        // focused-canvas rows, both, or neither. The app section supplies
        // its own separator, so an empty manage block must not add a second.
        let shapes = [
            snapshot(),
            snapshot(canUndoDisplacement: true, evictedCount: 1),
            snapshot(hasSplitterBackup: true),
            snapshot(
                tiledWindows: [.init(id: 1, slot: .topLeft, appName: nil)],
                untileCount: 1),
            snapshot(
                tiledWindows: [.init(id: 1, slot: .topLeft, appName: nil)],
                canUndoDisplacement: true,
                evictedCount: 1,
                untileCount: 1),
        ]
        for shape in shapes {
            let model = items(shape)
            for (index, item) in model.enumerated() where item.isSeparator {
                XCTAssertNotEqual(index, 0, "a separator never leads the menu")
                XCTAssertLessThan(
                    index, model.count - 1,
                    "a separator always separates two items")
                guard index + 1 < model.count else { continue }
                XCTAssertFalse(
                    model[index + 1].isSeparator,
                    "adjacent separators collapse into noise")
            }
        }
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
