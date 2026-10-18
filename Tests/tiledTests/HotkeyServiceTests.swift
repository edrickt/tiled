import Carbon.HIToolbox
import XCTest
@testable import tiled

/// HotkeyService's pure constants and the slot identifier scheme. The
/// registration behavior itself is pinned through the registrar seam in
/// `HotkeyRegistrationTests`; the invariants Carbon depends on are pinned
/// here.
final class HotkeyServiceTests: XCTestCase {
    func testSettingsFallbackComboIsAllFourModifiersPlusComma() {
        // Deliberately over-modified so it collides with nothing.
        XCTAssertEqual(
            HotkeyService.settingsModifiers,
            UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(HotkeyService.settingsKeyCode, UInt32(kVK_ANSI_Comma))
        XCTAssertEqual(HotkeyService.settingsDefaultBinding.label, "⌃⌥⇧⌘,")
    }

    /// Every configurable action — 17 slots + 5 app actions — gets a
    /// stable Carbon id, and no two share one: a collision would make one
    /// hotkey silently trigger another action.
    func testEveryActionHasAUniqueHotkeyID() {
        let ids = HotkeyAction.allCases.map(\.hotkeyID)
        XCTAssertEqual(ids.count, HotkeyAction.allCases.count)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(HotkeyAction.allCases.count, Slot.allCases.count + HotkeyAction.appActions.count)
    }

    /// App actions carry their identity: display titles for the Shortcuts
    /// tab rows and conflict messages, plus stable storage keys that keep
    /// slot overrides written by earlier builds resolvable.
    func testAppActionTitlesAndStorageKeys() {
        XCTAssertEqual(HotkeyAction.expand.title, "Expand to Fill Screen")
        XCTAssertEqual(HotkeyAction.evict.title, "Evict Focused Window")
        XCTAssertEqual(HotkeyAction.resetSplitters.title, "Reset Splitters")
        XCTAssertEqual(HotkeyAction.settings.title, "Open Settings")
        XCTAssertEqual(HotkeyAction.undo.title, "Undo Last Displacement")
        XCTAssertEqual(HotkeyAction.expand.storageKey, "action.expand")
        for slot in Slot.allCases {
            XCTAssertEqual(
                HotkeyAction.slot(slot).storageKey, slot.rawValue,
                "slot storage keys must stay the raw value for persistence compat")
        }
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
        XCTAssertEqual(HotkeyService.expandDefaultBinding.label, "⌥⇧⏎")
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

    func testEvictComboIsOptionShiftDelete() {
        // Fixed like expand's ⌥⇧⏎: it sits beside the quarters ⌥⇧ set but
        // on ⌫ (kVK_Delete), which no slot uses.
        XCTAssertEqual(HotkeyService.evictModifiers, UInt32(shiftKey | optionKey))
        XCTAssertEqual(HotkeyService.evictKeyCode, UInt32(kVK_Delete))
        XCTAssertEqual(HotkeyService.evictDefaultBinding.label, "⌥⇧⌫")
    }

    func testResetSplittersComboIsOptionShiftR() {
        // Fixed like expand's ⌥⇧⏎ and evict's ⌥⇧⌫: it sits beside the
        // sixths ⌥⇧ set but on R, which no slot defaults to.
        XCTAssertEqual(HotkeyService.resetSplittersModifiers, UInt32(shiftKey | optionKey))
        XCTAssertEqual(HotkeyService.resetSplittersKeyCode, UInt32(kVK_ANSI_R))
        XCTAssertEqual(HotkeyService.resetSplittersDefaultBinding.label, "⌥⇧R")
    }

    func testUndoComboIsAllFourModifiersPlusZ() {
        // The menu's undo row and the undo failure warning both promise
        // ⌃⌥⇧⌘Z. Pinned here so a keycode drift cannot make the advertised
        // combo a dead one.
        XCTAssertEqual(
            HotkeyService.undoModifiers,
            UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(HotkeyService.undoKeyCode, UInt32(kVK_ANSI_Z))
        XCTAssertEqual(
            HotkeyBinding(modifiers: HotkeyService.undoModifiers, keyCode: HotkeyService.undoKeyCode)
                .label, "⌃⌥⇧⌘Z")
    }

    func testUndoHotkeyIDCannotCollideWithSlotOrFixedIDs() {
        XCTAssertLessThan(UInt32(Slot.allCases.count), HotkeyService.undoHotkeyID)
        XCTAssertNotEqual(HotkeyService.undoHotkeyID, HotkeyService.expandHotkeyID)
        XCTAssertNotEqual(HotkeyService.undoHotkeyID, HotkeyService.evictHotkeyID)
        XCTAssertNotEqual(HotkeyService.undoHotkeyID, HotkeyService.settingsHotkeyID)
    }

    func testEvictHotkeyIDCannotCollideWithSlotOrFixedIDs() {
        XCTAssertLessThan(UInt32(Slot.allCases.count), HotkeyService.evictHotkeyID)
        XCTAssertNotEqual(HotkeyService.evictHotkeyID, HotkeyService.expandHotkeyID)
        XCTAssertNotEqual(HotkeyService.evictHotkeyID, HotkeyService.settingsHotkeyID)
        XCTAssertNotEqual(HotkeyService.evictHotkeyID, HotkeyService.undoHotkeyID)
    }

    func testResetSplittersHotkeyIDCannotCollideWithSlotOrFixedIDs() {
        XCTAssertLessThan(UInt32(Slot.allCases.count), HotkeyService.resetSplittersHotkeyID)
        XCTAssertNotEqual(HotkeyService.resetSplittersHotkeyID, HotkeyService.expandHotkeyID)
        XCTAssertNotEqual(HotkeyService.resetSplittersHotkeyID, HotkeyService.evictHotkeyID)
        XCTAssertNotEqual(HotkeyService.resetSplittersHotkeyID, HotkeyService.settingsHotkeyID)
        XCTAssertNotEqual(HotkeyService.resetSplittersHotkeyID, HotkeyService.undoHotkeyID)
    }

    func testQuartersAndSixthsModifierSets() {
        // Quarters add ⌘; sixths use ⌥⇧. Shared keycodes across layouts
        // (U/O/M/., J/L) are disambiguated by the modifier set.
        for slot in Slot.allCases where slot.layout == .quarters {
            XCTAssertEqual(
                slot.modifiers, UInt32(shiftKey | optionKey | cmdKey), "\(slot.rawValue)")
        }
        for slot in Slot.allCases where slot.layout == .sixths {
            XCTAssertEqual(
                slot.modifiers, UInt32(shiftKey | optionKey), "\(slot.rawValue)")
        }
    }

    func testRouteTableMapsEveryActionAndRejectsUnknownIDs() {
        // The production callback consumes this exact table. Every action
        // id maps to its own action, and unknown ids fall through.
        for action in HotkeyAction.allCases {
            XCTAssertEqual(
                HotkeyService.route(forHotKeyID: action.hotkeyID), action,
                "wrong route for \(action)")
        }
        // Known-good ids from the outside: slot ids are field order,
        // app-action ids are the reserved 995–999 range.
        XCTAssertEqual(HotkeyService.route(forHotKeyID: 1), .slot(.topLeft))
        XCTAssertEqual(HotkeyService.route(forHotKeyID: 998), .expand)
        XCTAssertEqual(HotkeyService.route(forHotKeyID: 996), .evict)
        XCTAssertEqual(HotkeyService.route(forHotKeyID: 999), .settings)
        XCTAssertEqual(HotkeyService.route(forHotKeyID: 997), .undo)
        XCTAssertEqual(HotkeyService.route(forHotKeyID: 995), .resetSplitters)
        for unknown: UInt32 in [0, 500, 994, 1000, 10_000] {
            XCTAssertNil(
                HotkeyService.route(forHotKeyID: unknown),
                "unknown id \(unknown) must fall through")
        }
        XCTAssertEqual(
            HotkeyService.actionByID.count, HotkeyAction.allCases.count,
            "one id per action, no aliases")
    }
}
