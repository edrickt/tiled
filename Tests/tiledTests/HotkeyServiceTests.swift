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

    /// Every configurable action — 11 slot keys + 6 app actions — gets a
    /// stable Carbon id, and no two share one: a collision would make one
    /// hotkey silently trigger another action.
    func testEveryActionHasAUniqueHotkeyID() {
        let ids = HotkeyAction.allCases.map(\.hotkeyID)
        XCTAssertEqual(ids.count, 17)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(
            HotkeyAction.allCases.count,
            SlotKey.allCases.count + HotkeyAction.appActions.count)
    }

    /// App actions carry their identity: display titles for the Shortcuts
    /// tab rows and conflict messages, plus stable storage keys that keep
    /// slot overrides written by earlier builds resolvable.
    func testAppActionTitlesAndStorageKeys() {
        XCTAssertEqual(HotkeyAction.expand.title, "Expand to Fill Screen")
        XCTAssertEqual(HotkeyAction.evict.title, "Evict Focused Window")
        XCTAssertEqual(HotkeyAction.resetSplitters.title, "Reset Splitters")
        XCTAssertEqual(HotkeyAction.switchLayout.title, "Switch Layout")
        XCTAssertEqual(HotkeyAction.settings.title, "Open Settings")
        XCTAssertEqual(HotkeyAction.undo.title, "Undo Last Displacement")
        XCTAssertEqual(HotkeyAction.expand.storageKey, "action.expand")
        XCTAssertEqual(HotkeyAction.switchLayout.storageKey, "action.switchLayout")
        // The persisted names are the sixths slots' raw values, so earlier
        // builds' overrides and parks keep resolving with no migration.
        let legacySixths: [SlotKey: String] = [
            .topLeft: "sixthTopLeft", .topMiddle: "sixthTopMiddle",
            .topRight: "sixthTopRight", .bottomLeft: "sixthBottomLeft",
            .bottomMiddle: "sixthBottomMiddle", .bottomRight: "sixthBottomRight",
            .leftColumn: "sixthLeft", .middleColumn: "sixthMiddle",
            .rightColumn: "sixthRight", .leftTwoThirds: "sixthsLeftTwoThirds",
            .rightTwoThirds: "sixthsRightTwoThirds",
        ]
        for key in SlotKey.allCases {
            XCTAssertEqual(
                HotkeyAction.slotKey(key).storageKey, legacySixths[key],
                "slot storage keys must stay the legacy sixths names")
        }
    }

    func testSettingsHotkeyIDCannotCollideWithSlotIDs() {
        // Slot ids occupy 1...allCases.count; the reserved id must stay
        // clear of that range even if slots are added.
        XCTAssertLessThan(UInt32(SlotKey.allCases.count), HotkeyService.settingsHotkeyID)
    }

    func testExpandComboIsOptionShiftReturn() {
        // Sits beside the quarters ⌥⇧ set but on Return, which no slot uses.
        XCTAssertEqual(HotkeyService.expandModifiers, UInt32(shiftKey | optionKey))
        XCTAssertEqual(HotkeyService.expandKeyCode, UInt32(kVK_Return))
        XCTAssertEqual(HotkeyService.expandDefaultBinding.label, "⌥⇧⏎")
    }

    func testExpandHotkeyIDCannotCollideWithSlotOrSettingsIDs() {
        XCTAssertLessThan(UInt32(SlotKey.allCases.count), HotkeyService.expandHotkeyID)
        XCTAssertLessThan(HotkeyService.expandHotkeyID, HotkeyService.settingsHotkeyID)
    }

    func testSlotHotkeyIDsAreUniqueAndSequential() {
        // Stable ids for Carbon events: every slot gets one, none repeat.
        let ids = SlotKey.allCases.map(\.hotkeyID)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids, (1...UInt32(SlotKey.allCases.count)).map { $0 })
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
        XCTAssertLessThan(UInt32(SlotKey.allCases.count), HotkeyService.undoHotkeyID)
        XCTAssertNotEqual(HotkeyService.undoHotkeyID, HotkeyService.expandHotkeyID)
        XCTAssertNotEqual(HotkeyService.undoHotkeyID, HotkeyService.evictHotkeyID)
        XCTAssertNotEqual(HotkeyService.undoHotkeyID, HotkeyService.settingsHotkeyID)
    }

    func testEvictHotkeyIDCannotCollideWithSlotOrFixedIDs() {
        XCTAssertLessThan(UInt32(SlotKey.allCases.count), HotkeyService.evictHotkeyID)
        XCTAssertNotEqual(HotkeyService.evictHotkeyID, HotkeyService.expandHotkeyID)
        XCTAssertNotEqual(HotkeyService.evictHotkeyID, HotkeyService.settingsHotkeyID)
        XCTAssertNotEqual(HotkeyService.evictHotkeyID, HotkeyService.undoHotkeyID)
    }

    func testResetSplittersHotkeyIDCannotCollideWithSlotOrFixedIDs() {
        XCTAssertLessThan(UInt32(SlotKey.allCases.count), HotkeyService.resetSplittersHotkeyID)
        XCTAssertNotEqual(HotkeyService.resetSplittersHotkeyID, HotkeyService.expandHotkeyID)
        XCTAssertNotEqual(HotkeyService.resetSplittersHotkeyID, HotkeyService.evictHotkeyID)
        XCTAssertNotEqual(HotkeyService.resetSplittersHotkeyID, HotkeyService.settingsHotkeyID)
        XCTAssertNotEqual(HotkeyService.resetSplittersHotkeyID, HotkeyService.undoHotkeyID)
    }

    func testEverySlotKeySharesTheOptionShiftModifierSet() {
        // One modifier set for both layouts: a layout switch never changes
        // the combo under the user's fingers.
        for key in SlotKey.allCases {
            XCTAssertEqual(
                key.defaultBinding.modifiers, UInt32(shiftKey | optionKey),
                "\(key.rawValue) must use ⌥⇧")
            XCTAssertEqual(
                key.defaultBinding.keyCode, key.keyCode, "\(key.rawValue) key code")
        }
        XCTAssertEqual(
            Set(SlotKey.allCases.map(\.defaultBinding.keyCode)).count,
            SlotKey.allCases.count, "no two keys share a keycap")
    }

    func testSwitchLayoutComboIsOptionShiftBackslash() {
        XCTAssertEqual(
            HotkeyService.switchLayoutModifiers, UInt32(shiftKey | optionKey))
        XCTAssertEqual(HotkeyService.switchLayoutKeyCode, UInt32(kVK_ANSI_Backslash))
        XCTAssertEqual(HotkeyService.switchLayoutDefaultBinding.label, "⌥⇧\\")
        XCTAssertEqual(HotkeyService.switchLayoutHotkeyID, 994)
    }

    func testRouteTableMapsEveryActionAndRejectsUnknownIDs() {
        // The production callback consumes this exact table. Every action
        // id maps to its own action, and unknown ids fall through.
        for action in HotkeyAction.allCases {
            XCTAssertEqual(
                HotkeyService.route(forHotKeyID: action.hotkeyID), action,
                "wrong route for \(action)")
        }
        // Known-good ids from the outside: slot-key ids are declaration
        // order, app-action ids the reserved 994–999 range.
        XCTAssertEqual(HotkeyService.route(forHotKeyID: 1), .slotKey(.topLeft))
        XCTAssertEqual(HotkeyService.route(forHotKeyID: 11), .slotKey(.rightTwoThirds))
        XCTAssertEqual(HotkeyService.route(forHotKeyID: 998), .expand)
        XCTAssertEqual(HotkeyService.route(forHotKeyID: 996), .evict)
        XCTAssertEqual(HotkeyService.route(forHotKeyID: 999), .settings)
        XCTAssertEqual(HotkeyService.route(forHotKeyID: 997), .undo)
        XCTAssertEqual(HotkeyService.route(forHotKeyID: 995), .resetSplitters)
        XCTAssertEqual(HotkeyService.route(forHotKeyID: 994), .switchLayout)
        for unknown: UInt32 in [0, 500, 1000, 10_000] {
            XCTAssertNil(
                HotkeyService.route(forHotKeyID: unknown),
                "unknown id \(unknown) must fall through")
        }
        XCTAssertEqual(
            HotkeyService.actionByID.count, HotkeyAction.allCases.count,
            "one id per action, no aliases")
    }
}
