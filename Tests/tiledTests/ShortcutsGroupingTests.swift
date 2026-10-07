import AppKit
import XCTest

@testable import tiled

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

    func testExpandedLayoutsGroupRecordersLikeTheMenuWithoutChangingBindings() {
        let custom = HotkeyBinding(modifiers: 0, keyCode: 0)
        store.set(custom, for: .sixthMiddle)
        let tab = ShortcutsTab(hotkeyStore: store, defaults: defaults)
        let view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        tab.reload()
        let headings = Set(["Quads", "Halves", "Corners", "Thirds", "Two-Thirds"])
        let sequence = descendants(of: view).compactMap { view -> String? in
            if let recorder = view as? RecorderButton {
                return recorder.slot.rawValue
            }
            if let label = view as? NSTextField, headings.contains(label.stringValue) {
                return label.stringValue
            }
            return nil
        }

        XCTAssertEqual(sequence, [
            "Quads", "topLeft", "topRight", "bottomLeft", "bottomRight",
            "Halves", "leftHalf", "rightHalf",
            "Corners", "sixthTopLeft", "sixthTopMiddle", "sixthTopRight",
            "sixthBottomLeft", "sixthBottomMiddle", "sixthBottomRight",
            "Thirds", "sixthLeft", "sixthMiddle", "sixthRight",
            "Two-Thirds", "sixthsLeftTwoThirds", "sixthsRightTwoThirds",
        ])
        XCTAssertEqual(store.binding(for: .sixthMiddle), custom)
        XCTAssertEqual(descendants(of: view).compactMap { $0 as? RecorderButton }
            .first { $0.slot == .sixthMiddle }?.accessibilityValue() as? String, "A")
    }

    func testCollapsingQuartersHidesItsSubgroupsAndKeepsSixthsAsTheFirstRecorder() throws {
        let tab = ShortcutsTab(hotkeyStore: store, defaults: defaults)
        var view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        tab.onContentRebuilt = { view = $0 }
        let header = try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSButton }
            .first { $0.title == "Quarters (6)" })
        header.performClick(nil)

        let labels = descendants(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertFalse(labels.contains("Quads"))
        XCTAssertFalse(labels.contains("Halves"))
        XCTAssertTrue(labels.contains("Corners"))
        XCTAssertTrue(labels.contains("Thirds"))
        XCTAssertTrue(labels.contains("Two-Thirds"))
        XCTAssertEqual(tab.firstRecorder?.slot, .sixthTopLeft)
        XCTAssertEqual(descendants(of: view).compactMap { $0 as? RecorderButton }.count, 11)

        // Collapse is persisted: a new tab reopens with the same layout hidden.
        let reopened = ShortcutsTab(hotkeyStore: store, defaults: defaults)
        _ = reopened.build(size: NSSize(width: 440, height: 480), window: nil)
        XCTAssertEqual(reopened.firstRecorder?.slot, .sixthTopLeft)
    }

    func testSixthsBulkActionStillCoversEverySubgroupAndLeavesQuartersAlone() throws {
        let tab = ShortcutsTab(hotkeyStore: store, defaults: defaults)
        var view = tab.build(size: NSSize(width: 440, height: 480), window: nil)
        tab.onContentRebuilt = { view = $0 }
        let previous = Dictionary(uniqueKeysWithValues: Slot.allCases.map { ($0, store.binding(for: $0)) })
        let disable = try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSButton }
            .first { $0.title == "Disable all 11" })
        disable.performClick(nil)

        for slot in Slot.allCases {
            if slot.layout == .sixths {
                XCTAssertNil(store.binding(for: slot).keyCode)
            } else {
                XCTAssertEqual(store.binding(for: slot), previous[slot])
            }
        }
        let enable = try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSButton }
            .first { $0.title == "Enable all 11" })
        enable.performClick(nil)
        for slot in Slot.allCases {
            XCTAssertEqual(store.binding(for: slot), previous[slot])
        }
    }
}
