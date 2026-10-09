import Carbon.HIToolbox
import XCTest
@testable import tiled

/// HotkeyService's pure constants, the slot identifier scheme, and the
/// event dispatch. The Carbon registration calls run through the injected
/// register/unregister seam; their register / reload / teardown lifecycle
/// is pinned in HotkeyServiceLifecycleTests, and the invariants it depends
/// on — plus the routing rule every press runs through — are pinned here.
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
        XCTAssertEqual(HotkeyAction.undo.title, "Undo Last Switch")
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

    func testCarbonEventIDRoutesToTheRightHandler() {
        // The dispatch's only routing logic — and the shape that runs:
        // production dispatch consumes this same rule — pinned as a table.
        // Every slot id routes to its slot, each reserved id to its own
        // action, and unknown ids route nowhere (eventNotHandledErr; the
        // event falls through to other apps instead of being swallowed).
        for slot in Slot.allCases {
            XCTAssertEqual(
                HotkeyService.route(forHotKeyID: slot.hotkeyID),
                .slot(slot), "\(slot.rawValue)")
        }
        XCTAssertEqual(
            HotkeyService.route(forHotKeyID: HotkeyService.expandHotkeyID),
            .expand)
        XCTAssertEqual(
            HotkeyService.route(forHotKeyID: HotkeyService.evictHotkeyID),
            .evict)
        XCTAssertEqual(
            HotkeyService.route(forHotKeyID: HotkeyService.settingsHotkeyID),
            .settings)
        XCTAssertEqual(
            HotkeyService.route(forHotKeyID: HotkeyService.undoHotkeyID),
            .undo)
        XCTAssertEqual(
            HotkeyService.route(forHotKeyID: HotkeyService.resetSplittersHotkeyID),
            .resetSplitters)
        for unknown: UInt32 in [0, 500, 994, 1000] {
            XCTAssertNil(
                HotkeyService.route(forHotKeyID: unknown),
                "unknown id \(unknown) must fall through")
        }
    }

    /// A press of a registered combo — Carbon delivering the hotkey event
    /// that carries its id — fires the handler with the action that id
    /// stands for, through the same routing rule the table above pins. The
    /// dispatch under test is the production one: the service's Carbon
    /// callback, the event object, and the handler.
    func testAHotkeyPressFiresTheHandlerWithTheActionItsIDStandsFor() {
        // The ids the table pins, fired as the events Carbon delivers.
        let presses: [(id: UInt32, action: HotkeyAction)] = [
            (HotkeyService.expandHotkeyID, .expand),
            (HotkeyService.evictHotkeyID, .evict),
            (HotkeyService.resetSplittersHotkeyID, .resetSplitters),
            (HotkeyService.settingsHotkeyID, .settings),
            (HotkeyService.undoHotkeyID, .undo),
            (Slot.topLeft.hotkeyID, .slot(.topLeft)),
            (Slot.sixthsRightTwoThirds.hotkeyID, .slot(.sixthsRightTwoThirds)),
        ]
        let (service, press) = makePressableService()
        var dispatched: [HotkeyAction] = []
        let eachPress = expectation(description: "every press is dispatched")
        eachPress.expectedFulfillmentCount = presses.count
        service.handler = { action in
            dispatched.append(action)
            eachPress.fulfill()
        }

        for (id, _) in presses {
            XCTAssertEqual(press(id), noErr, "id \(id)")
        }

        wait(for: [eachPress], timeout: 2)
        XCTAssertEqual(dispatched, presses.map(\.action))
    }

    /// An event carrying an id that is not ours routes nowhere: the
    /// callback answers eventNotHandledErr — the press falls through to
    /// other apps instead of being swallowed — and the handler stays out
    /// of it.
    func testAnUnknownHotkeyIDFallsThroughWithoutFiringTheHandler() {
        let (service, press) = makePressableService()
        service.handler = { _ in
            XCTFail("an unknown id must not dispatch an action")
        }

        XCTAssertEqual(press(500), OSStatus(eventNotHandledErr))

        // Drain the main queue to show the press scheduled no dispatch.
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    /// A service wired to capture its event-handler context, plus a
    /// `press` that fires a fabricated `kEventHotKeyPressed` at the
    /// service's Carbon callback — the exact event object the system
    /// delivers for a press of a registered combo — so the dispatch the
    /// tests drive is the dispatch production runs. Registration is a
    /// no-op: the tests press ids directly, no combos need to exist.
    private func makePressableService() -> (
        service: HotkeyService, press: (UInt32) -> OSStatus
    ) {
        var userData: UnsafeMutableRawPointer?
        let service = HotkeyService(
            register: { _, _, _, ref in
                ref = OpaquePointer(bitPattern: 0xCA11)
                return noErr
            },
            unregister: { _ in },
            install: { captured, ref in
                userData = captured
                ref = OpaquePointer(bitPattern: 0xCA11)
            },
            remove: { _ in })
        let press: (UInt32) -> OSStatus = { id in
            var event: EventRef?
            let created = CreateEvent(
                nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                0, 0, &event)
            guard created == noErr, let event else { return created }
            var hotKeyID = EventHotKeyID(
                signature: OSType(0x54_49_4C_44), // 'TILD', the service's
                id: id)
            let parameterSet = SetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                MemoryLayout<EventHotKeyID>.size,
                &hotKeyID)
            guard parameterSet == noErr else { return parameterSet }
            return HotkeyService.carbonCallback(nil, event, userData)
        }
        return (service, press)
    }
}
