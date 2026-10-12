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
            .init(title: "Built-in · Quarters · 2 tiled", key: display)
        ])
        XCTAssertEqual(presentation.tiledWindows.map(\.screen), [display, display])
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
            .init(title: "Display 1 · Quarters · 2 tiled", key: left),
            .init(title: "Display 2 · Sixths · 1 tiled", key: right),
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
            .init(title: "Display · Quarters · 2 tiled", key: display)
        ])
    }

    func testTwoDisplaysSharingANameRenderAsTwoSections() {
        // Two monitors can report the same localizedName. Identity, not
        // the shared name, decides the section: two sections, each with
        // its own layout and count, both headed by the same words.
        let left = ScreenID(rawValue: 0)
        let right = ScreenID(rawValue: 1)
        let rows = [
            row(1, .topLeft, screen: left, screenName: "Studio Display"),
            row(2, .sixthTopLeft, screen: right, screenName: "Studio Display"),
        ]

        let presentation = AppDelegate.monitorPresentation(
            rows: rows, layoutForScreen: { $0 == right ? .sixths : .quarters })

        XCTAssertEqual(presentation.sections, [
            .init(title: "Studio Display · Quarters · 1 tiled", key: left),
            .init(title: "Studio Display · Sixths · 1 tiled", key: right),
        ])
        XCTAssertEqual(presentation.tiledWindows.map(\.screen), [left, right])
        XCTAssertEqual(presentation.statusLine,
                       "Studio Display · Quarters · 1 tiled + Studio Display · Sixths · 1 tiled")
    }

    func testTwoUnlabeledDisplaysDoNotMergeIntoOneSection() {
        // Both displays fall back to the literal "Display": their
        // identities still keep them as two separate sections.
        let left = ScreenID(rawValue: 0)
        let right = ScreenID(rawValue: 1)
        let rows = [
            row(1, .topLeft, screen: left, screenName: nil),
            row(2, .topRight, screen: right, screenName: nil),
        ]

        let presentation = AppDelegate.monitorPresentation(
            rows: rows, layoutForScreen: { _ in .quarters })

        XCTAssertEqual(presentation.sections, [
            .init(title: "Display · Quarters · 1 tiled", key: left),
            .init(title: "Display · Quarters · 1 tiled", key: right),
        ])
    }

    func testOneDisplaysTwoCanvasesListEachWindowOnceUnderItsSection() {
        // A display can hold both an identified and a withheld canvas at
        // once, so `allTiledWindowsInfo` emits rows from both — same
        // display, same name. They are one display: every window lists
        // exactly once, under the one section keyed by that display's
        // ScreenID (never split by canvas, never doubled).
        let display = ScreenID(rawValue: 0)
        let rows = [
            row(1, .topLeft, screen: display, screenName: "Built-in"),
            row(2, .sixthTopLeft, screen: display, screenName: "Built-in"),
        ]

        let presentation = AppDelegate.monitorPresentation(
            rows: rows, layoutForScreen: { _ in .quarters })

        XCTAssertEqual(presentation.sections, [
            .init(title: "Built-in · Quarters · 2 tiled", key: display)
        ])
        XCTAssertEqual(presentation.tiledWindows.map(\.id), [1, 2])
        XCTAssertEqual(presentation.tiledWindows.map(\.screen), [display, display])
    }

    // MARK: Icon pass (iconSnapshot)

    func testIconPassResolvesTheFocusedCanvasOnce() {
        // The glyph must resolve one canvas key per pass and derive both
        // its occupancy map and its spoken display name from that single
        // key: a second resolution could land after a focus move and
        // describe a different canvas than the glyph. Counting the key
        // reads catches a regression that resolves it twice.
        let key = TilingSpaceKey(
            screen: ScreenID(rawValue: 1), space: SpaceID(rawValue: 7))
        var keyReads = 0
        var canvasKeys: [TilingSpaceKey] = []
        var nameKeys: [TilingSpaceKey] = []
        let snapshot = AppDelegate.iconSnapshot(
            canvasKey: { keyReads += 1; return key },
            canvas: { canvasKeys.append($0); return TilingSpace() },
            displayName: { nameKeys.append($0); return "Built-in" })

        XCTAssertEqual(keyReads, 1, "one canvas key resolution per icon pass")
        XCTAssertEqual(canvasKeys, [key])
        XCTAssertEqual(nameKeys, [key])
        XCTAssertEqual(snapshot.displayName, "Built-in")
    }

    // MARK: Refresh ordering (refreshPlan)

    func testIconChangeRedrawsWithoutRebuildingTheMenu() {
        // The status icon reads the focused display's occupancy, which the
        // menu snapshot deliberately aggregates across displays: a focus
        // move can change the glyph while the menu snapshot is identical.
        // The glyph must not ride the menu diff, or it freezes on the
        // display the user left until the next tiling action.
        let plan = AppDelegate.refreshPlan(
            menuChanged: false, iconChanged: true, menuOpen: false)

        XCTAssertTrue(plan.redrawIcon, "an icon-only change still redraws the glyph")
        XCTAssertFalse(plan.rebuildMenu, "an icon-only change never rebuilds the menu")
    }

    func testOpenMenuDefersBothHalvesOfTheRefresh() {
        // Rebuilding while the menu is open flickers or dismisses it; the
        // close handler runs a fresh pass.
        let plan = AppDelegate.refreshPlan(
            menuChanged: true, iconChanged: true, menuOpen: true)

        XCTAssertFalse(plan.redrawIcon)
        XCTAssertFalse(plan.rebuildMenu)
    }

    func testMenuChangeRebuildsAndRedrawsTheIcon() {
        let plan = AppDelegate.refreshPlan(
            menuChanged: true, iconChanged: true, menuOpen: false)

        XCTAssertTrue(plan.redrawIcon)
        XCTAssertTrue(plan.rebuildMenu)
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
