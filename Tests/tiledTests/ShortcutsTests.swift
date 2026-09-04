import XCTest
@testable import tiled

/// The Shortcuts window and the status menu derive from the same Slot
/// titles and hotkey labels — this pins the cheatsheet to every slot so a
/// new slot without a documented shortcut fails loudly.
final class ShortcutsTests: XCTestCase {
    func testCheatsheetMentionsEverySlot() {
        let text = Slot.cheatsheetText
        for slot in Slot.allCases {
            XCTAssertTrue(text.contains(slot.title), "\(slot.rawValue) title missing")
            XCTAssertTrue(text.contains(slot.hotkeyLabel), "\(slot.rawValue) hotkey missing")
        }
    }

    func testCheatsheetListsOneShortcutPerSlot() {
        let lines = Slot.cheatsheetText.components(separatedBy: "\n")
        let shortcutLines = lines.filter { $0.hasPrefix("⌥") }
        XCTAssertEqual(shortcutLines.count, Slot.allCases.count)
    }

    func testCheatsheetCoversBothLayouts() {
        XCTAssertTrue(Slot.cheatsheetText.contains("⌥⇧"))
        XCTAssertTrue(Slot.cheatsheetText.contains("⌥⇧⌘"))
    }
}
