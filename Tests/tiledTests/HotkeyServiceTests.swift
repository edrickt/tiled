import Carbon.HIToolbox
import XCTest
@testable import tiled

/// HotkeyService's pure constants and the slot identifier scheme. The
/// Carbon registration calls themselves need a live process and are not
/// unit-testable; the invariants they depend on are pinned here.
final class HotkeyServiceTests: XCTestCase {
    func testSettingsFallbackComboIsAllFourModifiersPlusComma() {
        // Deliberately over-modified so it collides with nothing.
        XCTAssertEqual(
            HotkeyService.settingsModifiers,
            UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(HotkeyService.settingsKeyCode, UInt32(kVK_ANSI_Comma))
    }

    func testSettingsHotkeyIDCannotCollideWithSlotIDs() {
        // Slot ids occupy 1...allCases.count; the reserved id must stay
        // clear of that range even if slots are added.
        XCTAssertLessThan(UInt32(Slot.allCases.count), HotkeyService.settingsHotkeyID)
    }

    func testExpandComboIsOptionShiftReturn() {
        // Sits beside the quarters ⌥⇧ set but on Return, which no slot uses.
        XCTAssertEqual(HotkeyService.expandModifiers, UInt32(shiftKey | optionKey))
        XCTAssertEqual(HotkeyService.expandKeyCode, UInt32(kVK_Return))
        XCTAssertEqual(HotkeyService.expandBinding.label, "⌥⇧⏎")
    }

    func testExpandHotkeyIDCannotCollideWithSlotOrSettingsIDs() {
        XCTAssertLessThan(UInt32(Slot.allCases.count), HotkeyService.expandHotkeyID)
        XCTAssertLessThan(HotkeyService.expandHotkeyID, HotkeyService.settingsHotkeyID)
    }

    func testSlotHotkeyIDsAreUniqueAndSequential() {
        // Stable ids for Carbon events: every slot gets one, none repeat.
        let ids = Slot.allCases.map(\.hotkeyID)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids, (1...UInt32(Slot.allCases.count)).map { $0 })
    }

    func testQuartersAndSixthsModifierSets() {
        // Quarters use ⌥⇧; sixths add ⌘. Shared keycodes across layouts
        // (U/O/M/., J/L) are disambiguated by the modifier set.
        for slot in Slot.allCases where slot.layout == .quarters {
            XCTAssertEqual(
                slot.modifiers, UInt32(shiftKey | optionKey), "\(slot.rawValue)")
        }
        for slot in Slot.allCases where slot.layout == .sixths {
            XCTAssertEqual(
                slot.modifiers, UInt32(shiftKey | optionKey | cmdKey), "\(slot.rawValue)")
        }
    }
}
