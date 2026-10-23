import Carbon.HIToolbox
import XCTest
@testable import tiled

/// The shared ⌥⇧ keys are one table: eleven physical positions, each with a
/// fixed keycode and title, and one slot per layout. These tests read the
/// table as literals from the product sketch, so a drifted keycode, title,
/// storage name, or slot mapping fails here rather than in a live press.
final class SlotKeyTests: XCTestCase {
    /// One row of the published key table. `quartersSlot` is nil for the
    /// five keys quarters has no position for.
    private struct Row {
        let key: SlotKey
        let keyCode: UInt32
        let title: String
        let storageKey: String
        let quartersSlot: Slot?
        let sixthsSlot: Slot?
    }

    private static let table: [Row] = [
        Row(
            key: .topLeft, keyCode: UInt32(kVK_ANSI_U), title: "Top Left",
            storageKey: "sixthTopLeft", quartersSlot: .topLeft,
            sixthsSlot: .sixthTopLeft),
        Row(
            key: .topMiddle, keyCode: UInt32(kVK_ANSI_I), title: "Top Middle",
            storageKey: "sixthTopMiddle", quartersSlot: nil,
            sixthsSlot: .sixthTopMiddle),
        Row(
            key: .topRight, keyCode: UInt32(kVK_ANSI_O), title: "Top Right",
            storageKey: "sixthTopRight", quartersSlot: .topRight,
            sixthsSlot: .sixthTopRight),
        Row(
            key: .bottomLeft, keyCode: UInt32(kVK_ANSI_M), title: "Bottom Left",
            storageKey: "sixthBottomLeft", quartersSlot: .bottomLeft,
            sixthsSlot: .sixthBottomLeft),
        Row(
            key: .bottomMiddle, keyCode: UInt32(kVK_ANSI_Comma), title: "Bottom Middle",
            storageKey: "sixthBottomMiddle", quartersSlot: nil,
            sixthsSlot: .sixthBottomMiddle),
        Row(
            key: .bottomRight, keyCode: UInt32(kVK_ANSI_Period), title: "Bottom Right",
            storageKey: "sixthBottomRight", quartersSlot: .bottomRight,
            sixthsSlot: .sixthBottomRight),
        Row(
            key: .leftColumn, keyCode: UInt32(kVK_ANSI_J), title: "Left Column",
            storageKey: "sixthLeft", quartersSlot: .leftHalf,
            sixthsSlot: .sixthLeft),
        Row(
            key: .middleColumn, keyCode: UInt32(kVK_ANSI_K), title: "Middle Column",
            storageKey: "sixthMiddle", quartersSlot: nil,
            sixthsSlot: .sixthMiddle),
        Row(
            key: .rightColumn, keyCode: UInt32(kVK_ANSI_L), title: "Right Column",
            storageKey: "sixthRight", quartersSlot: .rightHalf,
            sixthsSlot: .sixthRight),
        Row(
            key: .leftTwoThirds, keyCode: UInt32(kVK_ANSI_H), title: "Left Two-Thirds",
            storageKey: "sixthsLeftTwoThirds", quartersSlot: nil,
            sixthsSlot: .sixthsLeftTwoThirds),
        Row(
            key: .rightTwoThirds, keyCode: UInt32(kVK_ANSI_Semicolon),
            title: "Right Two-Thirds", storageKey: "sixthsRightTwoThirds",
            quartersSlot: nil, sixthsSlot: .sixthsRightTwoThirds),
    ]

    func testEveryKeyMatchesThePublishedTable() {
        // The declaration order is part of the contract: the Shortcuts tab
        // groups rows by it, and Carbon ids derive from it.
        XCTAssertEqual(SlotKey.allCases, Self.table.map(\.key))
        for row in Self.table {
            XCTAssertEqual(row.key.keyCode, row.keyCode, "\(row.key) keycode")
            XCTAssertEqual(row.key.title, row.title, "\(row.key) title")
            XCTAssertEqual(row.key.storageKey, row.storageKey, "\(row.key) storage key")
            XCTAssertEqual(
                row.key.slot(in: .quarters), row.quartersSlot,
                "\(row.key) quarters slot")
            XCTAssertEqual(
                row.key.slot(in: .sixths), row.sixthsSlot,
                "\(row.key) sixths slot")
        }
    }

    func testEverySlotHasExactlyOneKeyAndEveryKeyHasASixthsSlot() {
        // One key per slot per layout: a press has exactly one meaning, and
        // no slot is unreachable from the shared keys.
        for slot in Slot.allCases {
            let keys = SlotKey.allCases.filter { $0.slot(in: slot.layout) == slot }
            XCTAssertEqual(keys.count, 1, "\(slot.rawValue) in \(slot.layout)")
            XCTAssertEqual(slot.key.slot(in: slot.layout), slot, "\(slot.rawValue) key")
        }
        for key in SlotKey.allCases {
            XCTAssertNotNil(key.slot(in: .sixths), "\(key) has no sixths slot")
        }
    }

    func testStorageKeysAndHotkeyIDsAreUnique() {
        XCTAssertEqual(Set(SlotKey.allCases.map(\.storageKey)).count, 11)
        XCTAssertEqual(
            Set(SlotKey.allCases.map(\.hotkeyID)), Set((1...11).map(UInt32.init)))
    }

    func testEveryDefaultBindingIsOptionShiftPlusItsKey() {
        let optionShift = UInt32(optionKey | shiftKey)
        for key in SlotKey.allCases {
            let binding = key.defaultBinding
            XCTAssertEqual(binding.modifiers, optionShift, "\(key) modifiers")
            XCTAssertEqual(binding.keyCode, key.keyCode, "\(key) keycode")
        }
    }
}
