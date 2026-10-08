import XCTest

@testable import tiled

/// Pins the menu presentation logic extracted from AppDelegate:
/// multi-monitor grouping of the manage list (sections, per-display
/// counts, per-display layouts, status line) and the Action → selector
/// wiring (every case, so a selector or represented-object typo cannot
/// degrade a menu row into a silent no-op).
final class AppDelegateMenuTests: XCTestCase {
    // MARK: Monitor grouping (monitorPresentation)

    private func row(
        _ id: WindowID, _ slot: Slot, _ appName: String? = "App",
        screen: ScreenID? = nil, screenName: String? = nil
    ) -> TilingController.TiledWindowInfo {
        .init(id: id, slot: slot, appName: appName, screen: screen, screenName: screenName)
    }

    func testUntaggedRowsGroupUnderTheDisplayFallbackHeader() {
        // Rows with no screen tags still group under one "Display" header:
        // the nil key exists in the grouping dictionary, so the single-
        // group check treats it as grouped. (The truly flat branch is
        // reachable only with zero rows (see the empty test above).)
        let rows = [
            row(1, .topLeft),
            row(2, .topRight),
        ]

        let presentation = AppDelegate.monitorPresentation(
            rows: rows, layoutForScreen: { _ in .quarters })

        XCTAssertEqual(presentation.sections, [
            .init(title: "Display · Quarters · 2 tiled", key: nil)
        ])
        XCTAssertEqual(presentation.tiledWindows.map(\.id), [1, 2])
        XCTAssertEqual(presentation.statusLine, "Display · Quarters · 2 tiled")
    }

    func testOneTaggedDisplayStillGroups() {
        // Even a single display renders its header when rows carry tags:
        // the per-display status line ("Display 1 · Quarters · 2 tiled")
        // is how multi-monitor users read the compass.
        let display = ScreenID(rawValue: 0)
        let rows = [
            row(1, .topLeft, screen: display, screenName: "Built-in"),
            row(2, .topRight, screen: display, screenName: "Built-in"),
        ]

        let presentation = AppDelegate.monitorPresentation(
            rows: rows, layoutForScreen: { _ in .quarters })

        XCTAssertEqual(presentation.sections, [
            .init(title: "Built-in · Quarters · 2 tiled", key: "Built-in")
        ])
        XCTAssertEqual(presentation.tiledWindows.map(\.screenName), ["Built-in", "Built-in"])
        XCTAssertEqual(presentation.statusLine, "Built-in · Quarters · 2 tiled")
    }

    func testNoWindowsAtAllRendersTheEmptyStatusLine() {
        let presentation = AppDelegate.monitorPresentation(
            rows: [], layoutForScreen: { _ in .sixths })

        XCTAssertTrue(presentation.sections.isEmpty)
        XCTAssertTrue(presentation.tiledWindows.isEmpty)
        XCTAssertEqual(presentation.statusLine, "Layout: Sixths · 0 tiled")
    }

    func testTwoDisplaysGroupRowsPerDisplayInControllerOrder() {
        let left = ScreenID(rawValue: 0)
        let right = ScreenID(rawValue: 1)
        // Controller order interleaves displays; sections appear in
        // first-encounter order, rows keep their original order.
        let rows = [
            row(1, .topLeft, screen: left, screenName: "Display 1"),
            row(2, .sixthTopLeft, screen: right, screenName: "Display 2"),
            row(3, .bottomLeft, screen: left, screenName: "Display 1"),
        ]

        let presentation = AppDelegate.monitorPresentation(
            rows: rows, layoutForScreen: { $0 == right ? .sixths : .quarters })

        XCTAssertEqual(presentation.sections, [
            .init(title: "Display 1 · Quarters · 2 tiled", key: "Display 1"),
            .init(title: "Display 2 · Sixths · 1 tiled", key: "Display 2"),
        ])
        XCTAssertEqual(presentation.tiledWindows.map(\.id), [1, 2, 3])
        XCTAssertEqual(presentation.statusLine,
                       "Display 1 · Quarters · 2 tiled + Display 2 · Sixths · 1 tiled")
    }

    func testSectionTitlesUseTheSingularAndPluralNoun() {
        let display = ScreenID(rawValue: 0)
        let one = AppDelegate.monitorPresentation(
            rows: [row(1, .topLeft, screen: display, screenName: "D")],
            layoutForScreen: { _ in .quarters })
        XCTAssertEqual(one.sections.first?.title, "D · Quarters · 1 tiled")

        let two = AppDelegate.monitorPresentation(
            rows: [
                row(1, .topLeft, screen: display, screenName: "D"),
                row(2, .bottomLeft, screen: display, screenName: "D"),
            ],
            layoutForScreen: { _ in .quarters })
        XCTAssertEqual(two.sections.first?.title, "D · Quarters · 2 tiled")
    }

    func testNilScreenNameFallsBackToDisplayWhenGrouped() {
        // A row carrying a screen id but no name (unlabeled display)
        // groups under the positional fallback.
        let display = ScreenID(rawValue: 0)
        let rows = [
            row(1, .topLeft, screen: display, screenName: nil),
            row(2, .topRight, screen: display, screenName: nil),
        ]

        let presentation = AppDelegate.monitorPresentation(
            rows: rows, layoutForScreen: { _ in .quarters })

        XCTAssertEqual(presentation.sections, [
            .init(title: "Display · Quarters · 2 tiled", key: nil)
        ])
    }

    // MARK: Refresh ordering (refreshPlan)

    private func rendered(
        notice: String? = nil,
        layout: LayoutKind = .quarters,
        filled: [Slot] = [],
        occupied: Int = 0
    ) -> AppDelegate.RenderedMenuBar {
        AppDelegate.RenderedMenuBar(
            menu: MenuModel.Snapshot(
                isTrusted: true, warnings: [], notice: notice, layoutTitle: "",
                activeLayout: layout, tileError: nil, hasHotkeyWarnings: false,
                hasSplitterBackup: false, hasFocusedWindow: false, expandedSlot: nil,
                tiledWindows: [], canUndoDisplacement: false, evictedCount: 0, untileCount: 0),
            icon: StatusIcon.Snapshot(layout: layout, filled: filled, occupiedSlots: occupied))
    }

    func testIconChangeRedrawsWithoutRebuildingTheMenu() {
        // The status icon reads the focused display's occupancy, which the
        // menu snapshot deliberately aggregates across displays: a focus
        // move can change the glyph while the menu snapshot is identical.
        // The glyph must not ride the menu diff, or it freezes on the
        // display the user left until the next tiling action.
        let last = rendered()
        let next = rendered(filled: [.topLeft], occupied: 1)
        let plan = AppDelegate.refreshPlan(
            next: next, lastMenu: last.menu, lastIcon: last.icon,
            hasMenu: true, hasImage: true, menuOpen: false)

        XCTAssertTrue(plan.redrawIcon, "an icon-only change still redraws the glyph")
        XCTAssertFalse(plan.rebuildMenu, "an icon-only change never rebuilds the menu")
    }

    func testMenuChangeRebuildsWithoutRedrawingTheIcon() {
        // The mirror: a changed menu with an equal glyph leaves the icon
        // alone. Both diffs are read once, in this one pass.
        let last = rendered()
        let next = rendered(notice: "Evicted")
        let plan = AppDelegate.refreshPlan(
            next: next, lastMenu: last.menu, lastIcon: last.icon,
            hasMenu: true, hasImage: true, menuOpen: false)

        XCTAssertFalse(plan.redrawIcon, "an unchanged glyph is not redrawn")
        XCTAssertTrue(plan.rebuildMenu, "a menu change rebuilds the rows")
    }

    func testOpenMenuDefersBothHalvesOfTheRefresh() {
        // Rebuilding while the menu is open flickers or dismisses it; the
        // close handler runs a fresh pass.
        let next = rendered(notice: "Evicted", filled: [.topLeft], occupied: 1)
        let plan = AppDelegate.refreshPlan(
            next: next, lastMenu: nil, lastIcon: nil,
            hasMenu: true, hasImage: true, menuOpen: true)

        XCTAssertFalse(plan.redrawIcon)
        XCTAssertFalse(plan.rebuildMenu)
    }

    func testForceRebuildsTheMenuPastTheDiff() {
        // Binding labels live in menu titles but not the snapshot, so a
        // binding edit forces the rebuild even when the snapshot is equal.
        let same = rendered()
        let plan = AppDelegate.refreshPlan(
            next: same, lastMenu: same.menu, lastIcon: same.icon,
            hasMenu: true, hasImage: true, menuOpen: false, force: true)

        XCTAssertTrue(plan.rebuildMenu)
    }

    func testFirstPassRendersWhenNothingIsInstalledYet() {
        let next = rendered(filled: [.topLeft], occupied: 1)
        let plan = AppDelegate.refreshPlan(
            next: next, lastMenu: next.menu, lastIcon: next.icon,
            hasMenu: false, hasImage: false, menuOpen: false)

        XCTAssertTrue(plan.redrawIcon, "no image yet: draw one")
        XCTAssertTrue(plan.rebuildMenu, "no menu yet: install one")
    }

    // MARK: Action wiring (menuWiring)

    func testEveryActionWiresItsSelectorAndRepresentedObject() {
        // One assertion per Action case: the mapping is the only thing
        // between a click and its handler, and a mismatch there is a
        // silent no-op row. Selectors pinned by name: the wiring lives
        // on private @objc methods, so #selector is not referable here.
        let cases: [(MenuModel.Action, String, Any?, Bool)] = [
            (.tileSlot(.topLeft), "tileSlot:", Slot.topLeft.rawValue, true),
            (.toggleExpand, "expandFocusedWindow:", nil, true),
            (.evictFocusedWindow, "evictFocusedWindow:", nil, true),
            (.switchToQuarters, "switchToQuarters:", nil, true),
            (.switchToSixths, "switchToSixths:", nil, true),
            (.untileWindow(7), "untileTiledWindow:", 7, true),
            (.focusWindow(9), "focusTiledWindow:", 9, true),
            (.tileHere(.sixthMiddle), "tileFocusedHere:", Slot.sixthMiddle.rawValue, true),
            (.undoSwitch, "undoSwitch:", nil, true),
            (.untileAll, "untileAll:", nil, true),
            (.resetDividers, "resetDividers:", nil, true),
            (.showGuide, "showGuide:", nil, true),
            (.showSettings, "showSettings:", nil, true),
            (.openAccessibilitySettings, "openAccessibilitySettings:", nil, true),
            (.openShortcuts, "openShortcuts:", nil, true),
            // Quit rides the responder chain: no delegate target.
            (.quit, "terminate:", nil, false),
        ]
        for (action, selectorName, represented, targetsSelf) in cases {
            let wiring = AppDelegate.menuWiring(for: action)
            XCTAssertEqual(NSStringFromSelector(wiring.selector), selectorName, "\(action)")
            switch (wiring.representedObject, represented) {
            case (nil, nil):
                break
            case (let got as String, let expected as String):
                XCTAssertEqual(got, expected, "\(action)")
            case (let got as Int, let expected as Int):
                XCTAssertEqual(got, expected, "\(action)")
            default:
                XCTFail("represented object mismatch for \(action)")
            }
            XCTAssertEqual(wiring.targetsSelf, targetsSelf, "\(action)")
        }
    }
}
