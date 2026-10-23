import Carbon.HIToolbox
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

        let presentation = MenuReads.monitorPresentation(
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

        let presentation = MenuReads.monitorPresentation(
            rows: rows, layoutForScreen: { _ in .quarters })

        XCTAssertEqual(presentation.sections, [
            .init(title: "Built-in · Quarters · 2 tiled", key: display)
        ])
        XCTAssertEqual(presentation.tiledWindows.map(\.screen), [display, display])
        XCTAssertEqual(presentation.statusLine, "Built-in · Quarters · 2 tiled")
    }

    func testNoWindowsAtAllRendersTheEmptyStatusLine() {
        let presentation = MenuReads.monitorPresentation(
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

        let presentation = MenuReads.monitorPresentation(
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
        let one = MenuReads.monitorPresentation(
            rows: [row(1, .topLeft, screen: display, screenName: "D")],
            layoutForScreen: { _ in .quarters })
        XCTAssertEqual(one.sections.first?.title, "D · Quarters · 1 tiled")

        let two = MenuReads.monitorPresentation(
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

        let presentation = MenuReads.monitorPresentation(
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

        let presentation = MenuReads.monitorPresentation(
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

        let presentation = MenuReads.monitorPresentation(
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

        let presentation = MenuReads.monitorPresentation(
            rows: rows, layoutForScreen: { _ in .quarters })

        XCTAssertEqual(presentation.sections, [
            .init(title: "Built-in · Quarters · 2 tiled", key: display)
        ])
        XCTAssertEqual(presentation.tiledWindows.map(\.id), [1, 2])
        XCTAssertEqual(presentation.tiledWindows.map(\.screen), [display, display])
    }

    func testOneDisplaysTwoCanvasesListTheSameWindowOnce() {
        // The same window can be emitted from both of a display's canvases
        // (an identified and a withheld one). It is one window: the manage
        // list lists it once and counts it once, never twice.
        let display = ScreenID(rawValue: 0)
        let rows = [
            row(1, .topLeft, screen: display, screenName: "Built-in"),
            row(1, .topLeft, screen: display, screenName: "Built-in"),
        ]

        let presentation = MenuReads.monitorPresentation(
            rows: rows, layoutForScreen: { _ in .quarters })

        XCTAssertEqual(presentation.sections, [
            .init(title: "Built-in · Quarters · 1 tiled", key: display)
        ])
        XCTAssertEqual(presentation.tiledWindows.map(\.id), [1])
        XCTAssertEqual(
            presentation.statusLine, "Built-in · Quarters · 1 tiled",
            "the same window is counted once in the status line")
    }

    // MARK: Icon pass (iconSnapshot)

    func testIconPassDerivesItsReadsFromTheGivenKey() {
        // The glyph takes an already-resolved key and derives both its
        // occupancy map and its spoken display name from it, so a focus
        // move can never pair one canvas's glyph with another canvas's
        // name.
        let key = TilingSpaceKey(
            screen: ScreenID(rawValue: 1), space: SpaceID(rawValue: 7))
        var canvasKeys: [TilingSpaceKey] = []
        var nameKeys: [TilingSpaceKey] = []
        let snapshot = MenuBarPresenter.iconSnapshot(
            space: key,
            canvas: { canvasKeys.append($0); return TilingSpace() },
            displayName: { nameKeys.append($0); return "Built-in" })

        XCTAssertEqual(canvasKeys, [key])
        XCTAssertEqual(nameKeys, [key])
        XCTAssertEqual(snapshot.displayName, "Built-in")
    }

    func testOneSnapshotPassScopesBothHalvesToTheGivenCanvasKey() {
        // The menu-open path and the refresh path share one pass: the
        // presenter builds the menu and glyph from the key it is handed, so
        // a display change that lands mid-pass cannot leave them describing
        // different canvases. A background key with its own error and
        // display name proves both halves stay scoped to it even when focus
        // sits elsewhere.
        let left = ScreenInfo(
            id: ScreenID(rawValue: 1),
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            name: "Built-in")
        let right = ScreenInfo(
            id: ScreenID(rawValue: 2),
            frame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1600, height: 1000),
            name: "Studio Display")
        let gateway = FakeWindowGateway()
        let controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            screens: { [left, right] }, deathConfirmation: 0)
        controller.onChange = {}
        let safari = gateway.addWindow(
            frame: CGRect(x: 2000, y: 100, width: 800, height: 600), appName: "Safari")
        gateway.focused = safari
        controller.handle(slot: .topLeft)
        let mail = gateway.addWindow(
            frame: CGRect(x: 2000, y: 700, width: 800, height: 300), appName: "Mail")
        gateway.focused = mail
        gateway.refuseNextWrites(mail)
        controller.handle(slot: .bottomLeft)
        let notes = gateway.addWindow(
            frame: CGRect(x: 100, y: 100, width: 800, height: 600), appName: "Notes")
        gateway.focused = notes
        XCTAssertEqual(controller.focusedTilingSpace.screen, left.id)

        let presenter = MenuBarPresenter(
            controller: controller,
            hotkeyStore: HotkeyStore(
                defaults: UserDefaults(suiteName: "menu-pass-\(UUID())")!),
            hotkeyService: { nil },
            actionTarget: NSObject())
        let key = TilingSpaceKey(screen: right.id, space: nil)

        let snapshot = presenter.snapshot(for: key)

        XCTAssertEqual(
            snapshot.menu.tileError,
            "Mail couldn't be tiled: the app refused to resize it.",
            "the menu half describes the key it was handed, not focused Notes")
        XCTAssertEqual(snapshot.menu.untileCount, 1)
        XCTAssertEqual(
            snapshot.icon,
            StatusIcon.Snapshot(
                layout: .quarters,
                filled: [.topLeft],
                occupiedSlots: 1,
                displayName: "Studio Display"),
            "the glyph half names and fills the same passed canvas")
    }

    func testLabelOnlyRemapChangesThePresenterSnapshot() {
        // The store lives behind the presenter's snapshot assembly. Editing
        // one binding changes nothing but a label, yet the snapshot must
        // differ so the ordinary diff rebuilds the menu; this is the hole
        // `force:` used to patch.
        let defaults = UserDefaults(suiteName: "label-remap-\(UUID())")!
        let store = HotkeyStore(defaults: defaults)
        let controller = TilingController(
            gateway: FakeWindowGateway(), pruneInterval: nil,
            screens: { [ScreenInfo(
                id: ScreenID(rawValue: 1),
                frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                name: "Built-in")] },
            deathConfirmation: 0)
        controller.onChange = {}
        let presenter = MenuBarPresenter(
            controller: controller,
            hotkeyStore: store,
            hotkeyService: { nil },
            actionTarget: NSObject())

        let before = presenter.snapshot(for: controller.focusedTilingSpace)
        store.set(
            HotkeyBinding(
                modifiers: UInt32(optionKey), keyCode: UInt32(kVK_ANSI_Q)),
            for: .topLeft)
        let after = presenter.snapshot(for: controller.focusedTilingSpace)

        XCTAssertEqual(store.binding(for: .topLeft).label, "⌥Q")
        XCTAssertEqual(after.menu.labels[.slotKey(.topLeft)], "⌥Q")
        XCTAssertTrue(after.menu.isTrusted)
        XCTAssertEqual(after.menu.activeLayout, .sixths)
        XCTAssertNotEqual(
            before.menu, after.menu,
            "a label-only remap must be visible to the last-snapshot diff")
        let topLeft = MenuModel.items(snapshot: after.menu)
            .first { $0.title == "Tile Focused Window" }?
            .children?.first { $0.action == .tileSlot(.topLeft) }
        XCTAssertEqual(topLeft?.title, "Top Left · ⌥Q")
    }

    // MARK: Refresh ordering (refreshPlan)

    func testIconChangeRedrawsWithoutRebuildingTheMenu() {
        // The status icon reads the focused display's occupancy, which the
        // menu snapshot deliberately aggregates across displays: a focus
        // move can change the glyph while the menu snapshot is identical.
        // The glyph must not ride the menu diff, or it freezes on the
        // display the user left until the next tiling action.
        let plan = MenuBarPresenter.refreshPlan(
            menuChanged: false, iconChanged: true, menuOpen: false)

        XCTAssertTrue(plan.redrawIcon, "an icon-only change still redraws the glyph")
        XCTAssertFalse(plan.rebuildMenu, "an icon-only change never rebuilds the menu")
    }

    func testOpenMenuDefersBothHalvesOfTheRefresh() {
        // Rebuilding while the menu is open flickers or dismisses it; the
        // close handler runs a fresh pass.
        let plan = MenuBarPresenter.refreshPlan(
            menuChanged: true, iconChanged: true, menuOpen: true)

        XCTAssertFalse(plan.redrawIcon)
        XCTAssertFalse(plan.rebuildMenu)
    }

    func testMenuChangeRebuildsAndRedrawsTheIcon() {
        let plan = MenuBarPresenter.refreshPlan(
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
            (.tileSlot(.topLeft), "tileSlot:", SlotKey.topLeft.rawValue, true),
            (.toggleExpand, "expandFocusedWindow:", nil, true),
            (.evictFocusedWindow, "evictFocusedWindow:", nil, true),
            (.switchLayout(to: .sixths), "switchLayout:", LayoutKind.sixths.rawValue, true),
            (.switchLayout(to: .quarters), "switchLayout:", LayoutKind.quarters.rawValue, true),
            (.untileWindow(7), "untileTiledWindow:", 7, true),
            (.focusWindow(9), "focusTiledWindow:", 9, true),
            (.tileHere(.middleColumn), "tileFocusedHere:", SlotKey.middleColumn.rawValue, true),
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
