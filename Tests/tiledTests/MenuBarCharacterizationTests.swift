import Carbon.HIToolbox
import XCTest
@testable import tiled

/// Characterization pins for the menu bar before the presenter extraction.
/// Expected titles are literal strings in menu order, never values derived
/// from the same constants the menu code iterates, so a reordering or a
/// dropped row fails here. The fixed canvas set carries a notice, both
/// warning kinds, a splitter backup, a live undo chapter, two displays,
/// and a label-only hotkey remap.
final class MenuBarCharacterizationTests: XCTestCase {
    private static let screen = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        name: "Built-in")

    private let leftDisplay = ScreenID(rawValue: 1)
    private let rightDisplay = ScreenID(rawValue: 2)

    /// The fixed menu snapshot: two displays' rows, warnings, a notice, an
    /// expanded window returning to a half, undo and splitter receipts.
    private func fixedSnapshot() -> MenuModel.Snapshot {
        var snapshot = MenuModel.Snapshot(
            isTrusted: true,
            warnings: [
                "⌥⇧U could not be registered; “Top Left Sixth” has no hotkey.",
                "The Undo Last Displacement shortcut (⌃⌥⇧⌘Z) could not be registered; undo the last displacement from the Tiled menu instead.",
            ],
            notice: "Switched to Sixths · 1 window untiled.",
            layoutTitle: "Built-in · Quarters · 2 tiled + Studio Display · Sixths · 1 tiled",
            activeLayout: .quarters,
            tileError: "Safari couldn't be tiled: the app refused to resize it.",
            hasHotkeyWarnings: true,
            hasSplitterBackup: true,
            hasFocusedWindow: true,
            expandState: .returnsToSlot(.leftHalf),
            tiledWindows: [
                .init(id: 1, slot: .topLeft, appName: "Safari", screen: leftDisplay),
                .init(id: 2, slot: .leftHalf, appName: "Mail", screen: leftDisplay),
                .init(id: 3, slot: .sixthTopLeft, appName: "Notes", screen: rightDisplay),
            ],
            canUndoDisplacement: true,
            displacedCount: 2,
            untileCount: 2)
        snapshot.monitorSections = [
            .init(title: "Built-in · Quarters · 2 tiled", key: leftDisplay),
            .init(title: "Studio Display · Sixths · 1 tiled", key: rightDisplay),
        ]
        return snapshot
    }

    /// The live bindings for the fixed set. Top Left is deliberately remapped
    /// to a combo no default uses, so the pinned title proves the menu reads
    /// the store's label, not the slot's default.
    private func binding(_ action: HotkeyAction) -> HotkeyBinding {
        switch action {
        case .slot(.topLeft):
            HotkeyBinding(modifiers: UInt32(controlKey | optionKey), keyCode: UInt32(kVK_ANSI_Q))
        default:
            action.defaultBinding
        }
    }

    func testMenuTitlesAndOrderForAFixedCanvasSet() {
        let items = MenuModel.items(snapshot: fixedSnapshot(), binding: binding)

        XCTAssertEqual(items.map(\.title), [
            "Safari couldn't be tiled: the app refused to resize it.",
            "⚠ 2 shortcut problems: combos are taken",
            "Open Shortcuts…",
            "Switched to Sixths · 1 window untiled.",
            "Built-in · Quarters · 2 tiled + Studio Display · Sixths · 1 tiled",
            "",
            "Tile Focused Window",
            "Return to Left Half · ⌥⇧⏎",
            "Evict Focused Window · ⌥⇧⌫",
            "",
            "Built-in · Quarters · 2 tiled",
            "Top Left · Safari (⌃⌥Q)",
            "Left Half · Mail (⌥⇧⌘J)",
            "Studio Display · Sixths · 1 tiled",
            "Top Left Sixth · Notes (⌥⇧U)",
            "",
            "Restore 2 Displaced Windows · ⌃⌥⇧⌘Z",
            "Untile 2 Windows",
            "Restore Previous Splitters · ⌥⇧R",
            "",
            "Tiled Guide",
            "Settings…",
            "Quit Tiled",
        ])
        XCTAssertEqual(items.map(\.isEnabled), [
            false, false, true, false, false,
            true,
            true, true, true,
            true,
            false, true, true, false, true,
            true,
            true, true, true,
            true,
            true, true, true,
        ])
        XCTAssertEqual(items.last?.keyEquivalent, "q")
        XCTAssertEqual(items.first { $0.action == .showSettings }?.keyEquivalent, ",")
    }

    func testTileSubmenuTitlesAndOrderForQuarters() {
        let items = MenuModel.items(snapshot: fixedSnapshot(), binding: binding)
        let tile = items.first { $0.title == "Tile Focused Window" }!

        XCTAssertEqual(tile.children?.map(\.title), [
            "Quarters · Quads",
            "Top Left · ⌃⌥Q",
            "Top Right · ⌥⇧⌘O",
            "Bottom Left · ⌥⇧⌘M",
            "Bottom Right · ⌥⇧⌘.",
            "Halves",
            "Left Half · ⌥⇧⌘J",
            "Right Half · ⌥⇧⌘L",
            "",
            "Switch to Sixths (focused window → Top Left Sixth)",
        ])
        XCTAssertEqual(tile.children?.map(\.isEnabled), [
            false, true, true, true, true, false, true, true, true, true,
        ])
    }

    func testManageSubmenusForTheFixedWindows() {
        let items = MenuModel.items(snapshot: fixedSnapshot(), binding: binding)

        let safari = items.first { $0.title == "Top Left · Safari (⌃⌥Q)" }!
        XCTAssertEqual(safari.action, nil, "the manage row itself does not act")
        XCTAssertEqual(safari.children?.map(\.title), [
            "Untile This Window", "Focus Safari", "Tile Focused Window Here",
        ])
        XCTAssertEqual(safari.children?.map(\.action), [
            .untileWindow(1), .focusWindow(1), .tileHere(.topLeft),
        ])

        let mail = items.first { $0.title == "Left Half · Mail (⌥⇧⌘J)" }!
        XCTAssertEqual(mail.children?.map(\.title), [
            "Untile This Window", "Focus Mail", "Tile Focused Window Here",
        ])
        XCTAssertEqual(mail.children?.map(\.action), [
            .untileWindow(2), .focusWindow(2), .tileHere(.leftHalf),
        ])
    }

    func testALabelOnlyRemapChangesTheSnapshotVisibleOutput() {
        // The same menu state with only one binding label changed: the two
        // snapshots differ, so only a rebuild can show the new combo. Before
        // the labels live in the snapshot, this is the diff hole `force:`
        // patched; the literal titles below pin the two outputs.
        var remapped = fixedSnapshot()
        remapped.notice = nil
        let before = MenuModel.items(snapshot: remapped, binding: { $0.defaultBinding })
        let after = MenuModel.items(snapshot: remapped, binding: binding)
        let beforeTopLeft = before.first { $0.title == "Tile Focused Window" }?
            .children?.first { $0.action == .tileSlot(.topLeft) }
        let afterTopLeft = after.first { $0.title == "Tile Focused Window" }?
            .children?.first { $0.action == .tileSlot(.topLeft) }

        XCTAssertEqual(beforeTopLeft?.title, "Top Left · ⌥⇧⌘U")
        XCTAssertEqual(afterTopLeft?.title, "Top Left · ⌃⌥Q")
        XCTAssertNotEqual(before.map(\.title), after.map(\.title))
    }

    func testTheFixedCanvasSetRendersTheLiteralStatusIconSnapshot() {
        // The same fixed canvas, read through the icon half of the refresh
        // pass: two quads occupied by two windows, one glyph cell each.
        let gateway = FakeWindowGateway()
        let controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            screens: { [Self.screen] }, deathConfirmation: 0)
        let safari = gateway.addWindow(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600), appName: "Safari")
        gateway.focused = safari
        controller.handle(slot: .topLeft)
        let mail = gateway.addWindow(
            frame: CGRect(x: 900, y: 0, width: 800, height: 600), appName: "Mail")
        gateway.focused = mail
        controller.handle(slot: .topRight)

        let icon = AppDelegate.iconSnapshot(
            space: controller.focusedTilingSpace,
            canvas: { controller.canvas(for: $0) },
            displayName: { _ in nil })

        XCTAssertEqual(icon, StatusIcon.Snapshot(
            layout: .quarters,
            filled: [.topLeft, .topRight],
            occupiedSlots: 2,
            displayName: nil))
    }

    // MARK: Feedback announcements preserved by the receipt cut

    /// What the current feedback channel says to the user, as the delegate
    /// composes it. Literal sentences so the receipt migration can prove it
    /// speaks the same words.
    private func announcement(for feedback: TilingController.Feedback) -> String {
        switch feedback {
        case .noFocusedWindow:
            "No focused window: click a window first."
        case .alreadyTiled(.topLeft):
            "Top Left: already there."
        case .alreadyTiled(let slot):
            "\(SlotPresentation.title(of: slot)): already there."
        case .refused(let name):
            "\(name ?? "That window") couldn't be tiled: the app refused to resize it."
        case .expandRefused(let name):
            "\(name ?? "That window") couldn't be expanded: the app refused to resize it."
        case .deferred:
            "That Space isn't visible yet: the change will apply when you return to it."
        }
    }

    func testSlotFeedbackForNoFocusAlreadyTiledRefusedAndDeferred() {
        let gateway = FakeWindowGateway()
        let screen = Self.screen
        let controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            screens: { [screen] }, deathConfirmation: 0)
        var feedbacks: [TilingController.Feedback] = []
        controller.onFeedback = { feedbacks.append($0) }

        // No focused window.
        controller.handle(slot: .topLeft)
        XCTAssertEqual(
            feedbacks.last.map { announcement(for: $0) },
            "No focused window: click a window first.")

        // Already there: the strict no-op answers once.
        let safari = gateway.addWindow(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600), appName: "Safari")
        gateway.focused = safari
        controller.handle(slot: .topLeft)
        controller.handle(slot: .topLeft)
        XCTAssertEqual(
            feedbacks.last.map { announcement(for: $0) }, "Top Left: already there.")

        // A refused write names the app, never a shortcut problem.
        let mail = gateway.addWindow(
            frame: CGRect(x: 900, y: 0, width: 800, height: 600), appName: "Mail")
        gateway.focused = mail
        gateway.refuseNextWrites(mail)
        controller.handle(slot: .topRight)
        XCTAssertEqual(
            feedbacks.last.map { announcement(for: $0) },
            "Mail couldn't be tiled: the app refused to resize it.")

        // A write deferred off-Space narrates the deferral, never a refusal.
        let displayID: CGDirectDisplayID = 42
        let spaceA = SpaceID(rawValue: 101)
        let spaceB = SpaceID(rawValue: 102)
        let spacedScreen = ScreenInfo(
            id: ScreenID(rawValue: 1),
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            name: "Built-in",
            displayID: displayID)
        let spaceGateway = FakeWindowGateway()
        spaceGateway.activeSpaces = [displayID: spaceA]
        let spaceController = TilingController(
            gateway: spaceGateway, pruneInterval: nil,
            screens: { [spacedScreen] }, deathConfirmation: 0)
        var spaceFeedbacks: [TilingController.Feedback] = []
        spaceController.onFeedback = { spaceFeedbacks.append($0) }
        let notes = spaceGateway.addWindow(
            frame: CGRect(x: 100, y: 100, width: 800, height: 600), appName: "Notes")
        spaceGateway.focused = notes
        spaceController.handle(slot: .topLeft)
        spaceGateway.activeSpaces = [displayID: spaceB]
        spaceGateway.simulateSpaceChange()
        spaceGateway.focused = notes
        spaceController.handle(slot: .topRight)
        XCTAssertEqual(
            spaceFeedbacks.last.map { announcement(for: $0) },
            "That Space isn't visible yet: the change will apply when you return to it.")
    }

    func testExpandFeedbackForNoFocusAndRefused() {
        let gateway = FakeWindowGateway()
        let screen = Self.screen
        let controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            screens: { [screen] }, deathConfirmation: 0)
        var feedbacks: [TilingController.Feedback] = []
        controller.onFeedback = { feedbacks.append($0) }

        controller.handleExpandToggle()
        XCTAssertEqual(
            feedbacks.last.map { announcement(for: $0) },
            "No focused window: click a window first.")

        let safari = gateway.addWindow(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600), appName: "Safari")
        gateway.focused = safari
        controller.handle(slot: .topLeft)
        gateway.refuseNextWrites(safari)
        controller.handleExpandToggle()
        XCTAssertEqual(
            feedbacks.last.map { announcement(for: $0) },
            "Safari couldn't be expanded: the app refused to resize it.")
    }
}
