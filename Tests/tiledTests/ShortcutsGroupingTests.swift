import AppKit
import XCTest

@testable import tiled

/// The Shortcuts tab has exactly two sections: the six app actions and the
/// eleven shared slot keys. The slot-key section is grouped by physical
/// position and carries the one bulk control.
final class ShortcutsGroupingTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: HotkeyStore!

    override func setUp() {
        super.setUp()
        suiteName = "ShortcutsGroupingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = HotkeyStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    func testSectionsGroupRecordersWithoutChangingBindings() {
        let custom = HotkeyBinding(modifiers: 0, keyCode: 0)
        store.set(custom, for: .middleColumn)
        let tab = ShortcutsTab(hotkeyStore: store, defaults: defaults)
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        tab.reload()
        let headings = Set(["Corners", "Thirds", "Two-Thirds"])
        let sequence = descendants(of: view).compactMap { view -> String? in
            if let recorder = view as? RecorderButton {
                if case .slotKey(let key) = recorder.hotkeyAction { return key.rawValue }
                return recorder.hotkeyAction.title
            }
            if let label = view as? NSTextField, headings.contains(label.stringValue) {
                return label.stringValue
            }
            return nil
        }

        XCTAssertEqual(sequence, [
            "Expand to Fill Screen", "Evict Focused Window", "Reset Splitters",
            "Switch Layout", "Open Settings", "Undo Last Displacement",
            "Corners",
            "topLeft", "topMiddle", "topRight",
            "bottomLeft", "bottomMiddle", "bottomRight",
            "Thirds", "leftColumn", "middleColumn", "rightColumn",
            "Two-Thirds", "leftTwoThirds", "rightTwoThirds",
        ])
        XCTAssertEqual(store.binding(for: .middleColumn), custom)
        XCTAssertEqual(
            descendants(of: view).compactMap { $0 as? RecorderButton }
                .first { $0.hotkeyAction == .slotKey(.middleColumn) }?
                .accessibilityValue() as? String,
            "A")
    }

    func testCollapsingSlotKeysHidesItsSubgroupsAndLeavesAppActionsLeading() throws {
        let tab = ShortcutsTab(hotkeyStore: store, defaults: defaults)
        var view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        tab.onContentRebuilt = { view = $0 }
        let header = try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSButton }
            .first { $0.title == "Slot Keys (11)" })
        header.performClick(nil)

        let labels = descendants(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertFalse(labels.contains("Corners"))
        XCTAssertFalse(labels.contains("Thirds"))
        XCTAssertFalse(labels.contains("Two-Thirds"))
        // Slot Keys collapses, but App Actions stays visible, so the first
        // recorder is Expand.
        XCTAssertEqual(tab.firstRecorder?.hotkeyAction, .expand)
        XCTAssertEqual(descendants(of: view).compactMap { $0 as? RecorderButton }.count, 6)

        // Collapse is persisted: a new tab reopens with the section hidden.
        let reopened = ShortcutsTab(hotkeyStore: store, defaults: defaults)
        _ = reopened.build(size: NSSize(width: 440, height: 480), window: nil)
        XCTAssertEqual(reopened.firstRecorder?.hotkeyAction, .expand)
    }

    func testCollapsingAppActionsHidesOnlyThoseSixRows() throws {
        let tab = ShortcutsTab(hotkeyStore: store, defaults: defaults)
        var view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        tab.onContentRebuilt = { view = $0 }
        let header = try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSButton }
            .first { $0.title == "App Actions (6)" })
        header.performClick(nil)

        let labels = descendants(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertFalse(labels.contains("Expand to Fill Screen"))
        XCTAssertFalse(labels.contains("Undo Last Displacement"))
        XCTAssertTrue(labels.contains("Corners"))
        // Slot Keys is expanded and starts right after the collapsed
        // section, so its first key leads.
        XCTAssertEqual(tab.firstRecorder?.hotkeyAction, .slotKey(.topLeft))
        XCTAssertEqual(descendants(of: view).compactMap { $0 as? RecorderButton }.count, 11)
    }

    func testBulkActionCoversEverySlotKeyAndLeavesAppActionsAlone() throws {
        let tab = ShortcutsTab(hotkeyStore: store, defaults: defaults)
        var view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        tab.onContentRebuilt = { view = $0 }
        let slotKeys = SlotKey.allCases.map(HotkeyAction.slotKey)
        let previousSlots = Dictionary(
            uniqueKeysWithValues: slotKeys.map { ($0, store.binding(for: $0)) })
        let previousApps = Dictionary(
            uniqueKeysWithValues: HotkeyAction.appActions.map { ($0, store.binding(for: $0)) })
        let disable = try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSButton }
            .first { $0.title == "Disable all 11" })
        disable.performClick(nil)

        for action in slotKeys {
            XCTAssertNil(store.binding(for: action).keyCode)
        }
        for action in HotkeyAction.appActions {
            XCTAssertEqual(store.binding(for: action), previousApps[action])
        }
        let enable = try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSButton }
            .first { $0.title == "Enable all 11" })
        enable.performClick(nil)
        for action in slotKeys {
            XCTAssertEqual(store.binding(for: action), previousSlots[action])
        }
    }
}
