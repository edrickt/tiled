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
        tiledWindows: [MenuModel.Snapshot.TiledWindow] = [],
        canUndoSwitch: Bool = false,
        evictedCount: Int = 0
    ) -> MenuModel.Snapshot {
        MenuModel.Snapshot(
            isTrusted: isTrusted,
            warnings: warnings,
            notice: notice,
            layoutTitle: layoutTitle,
            tiledWindows: tiledWindows,
            canUndoSwitch: canUndoSwitch,
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

    func testWarningsTakePrecedenceOverNoticeAndStatusLine() {
        let model = items(snapshot(
            warnings: ["⌥⇧U is already used by another app"],
            notice: "Switched to Sixths · 1 window untiled."))
        XCTAssertEqual(model.first?.title, "⌥⇧U is already used by another app")
        XCTAssertFalse(model.first!.isEnabled)
        XCTAssertFalse(
            model.contains { $0.title.hasPrefix("Layout:") },
            "warnings replace the status line entirely")
        XCTAssertFalse(
            model.contains { $0.title == "Switched to Sixths · 1 window untiled." },
            "a real error wins over a notice")
    }

    func testMultipleWarningsRenderOneRowEach() {
        let model = items(snapshot(warnings: ["a", "b"]))
        XCTAssertEqual(model.prefix(2).map(\.title), ["a", "b"])
        XCTAssertTrue(model.prefix(2).allSatisfy { !$0.isEnabled })
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

    func testTileSubmenuGroupsAllSeventeenSlots() {
        let tile = tileSubmenu(items(snapshot()))!
        let children = tile.children!
        // Headers and separators interleaved with slot items in order.
        let headers = children.filter(\.isHeader).map(\.title)
        XCTAssertEqual(headers, ["Quarters", "Sixths — Corners", "Thirds", "Two-Thirds"])
        let slotOrder = children.compactMap {
            if case .tileSlot(let slot)? = $0.action { return slot }
            return nil
        }
        XCTAssertEqual(slotOrder.count, Slot.allCases.count, "every slot gets a row")
        XCTAssertEqual(
            slotOrder,
            Slot.allCases.filter { $0.layout == .quarters }
                + SlotPresentation.sixthsCorners
                + SlotPresentation.sixthsThirds
                + SlotPresentation.sixthsTwoThirds)
        XCTAssertEqual(children.filter(\.isSeparator).count, 1)
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

    func testTileItemsCarryLiveLabelsFromTheStore() {
        let model = MenuModel.items(snapshot: snapshot()) { slot in
            switch slot {
            case .topLeft:
                return HotkeyBinding(modifiers: UInt32(optionKey), keyCode: UInt32(kVK_ANSI_Q))
            case .sixthRight:
                return HotkeyBinding(modifiers: 0, keyCode: nil) // disabled slot
            default:
                return HotkeyStore.defaultBinding(for: slot)
            }
        }
        let tile = model.first { $0.title == "Tile Focused Window" }!
        let topLeft = tile.children!.first { $0.title.contains("Top Left") }!
        XCTAssertEqual(topLeft.title, "Top Left — ⌥Q")
        XCTAssertEqual(topLeft.action, .tileSlot(.topLeft))
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
            canUndoSwitch: true, evictedCount: 2))
        let undo = withUndo.first { $0.action == .undoSwitch }
        XCTAssertEqual(undo?.title, "Restore 2 Evicted Windows")
        XCTAssertEqual(undo?.keyEquivalent, "z")

        let withoutUndo = items(snapshot(
            tiledWindows: [.init(id: 1, slot: .topLeft, appName: nil)],
            canUndoSwitch: false))
        XCTAssertFalse(withoutUndo.contains { $0.action == .undoSwitch })
        // Bulk actions still exist without undo.
        XCTAssertTrue(withoutUndo.contains { $0.action == .untileAll })
        XCTAssertTrue(withoutUndo.contains { $0.action == .resetDividers })
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
                model.suffix(3).map(\.title), ["tiled Guide", "Settings…", "Quit tiled"])
            XCTAssertEqual(model.last?.keyEquivalent, "q")
            XCTAssertEqual(model.first { $0.action == .showSettings }?.keyEquivalent, ",")
        }
    }
}
