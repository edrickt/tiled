import CoreGraphics
import XCTest

@testable import tiled

/// The directory's own rules: which canvases are visible, and which canvas
/// a display action falls back to while the window server withholds a
/// Space id.
final class CanvasDirectoryTests: XCTestCase {
    private static let displayID: CGDirectDisplayID = 42
    private static let otherDisplayID: CGDirectDisplayID = 43
    private static let screen = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        name: "Display 1",
        displayID: displayID)
    private static let otherScreen = ScreenInfo(
        id: ScreenID(rawValue: 2),
        frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        name: "Display 2",
        displayID: otherDisplayID)
    private static let space = SpaceID(rawValue: 101)

    private var activeSpaces: [CGDirectDisplayID: SpaceID] = [:]
    private var screens: [ScreenInfo] = []
    private var directory: CanvasDirectory!

    override func setUp() {
        super.setUp()
        screens = [Self.screen, Self.otherScreen]
        activeSpaces = [Self.displayID: Self.space]
        directory = CanvasDirectory(
            screens: { [weak self] in self?.screens ?? [] },
            activeSpace: { [weak self] in self?.activeSpaces[$0] },
            focusedWindow: { nil },
            frameOf: { _ in nil },
            preTileFrameOf: { _ in nil })
    }

    private var identified: TilingSpaceKey {
        TilingSpaceKey(screen: Self.screen.id, space: Self.space)
    }
    private var withheld: TilingSpaceKey {
        TilingSpaceKey(screen: Self.screen.id, space: nil)
    }
    private var otherIdentified: TilingSpaceKey {
        TilingSpaceKey(screen: Self.otherScreen.id, space: nil)
    }

    /// A chapter is enough for the withheld fallback: it is a canvas that
    /// still owes the user work, even with no occupant.
    private func holdAChapter(_ key: TilingSpaceKey) {
        directory.withCanvas(key) {
            $0.undoStack = [(snapshot: [], requester: nil)]
        }
    }

    func testVisibleKeysListsEveryDisplayWithItsWithheldCanvasWhenItHoldsWork() {
        XCTAssertEqual(
            directory.visibleKeys(), [identified, otherIdentified],
            "a fresh display still enumerates its identified canvas")

        holdAChapter(withheld)

        XCTAssertEqual(
            directory.visibleKeys(), [identified, withheld, otherIdentified],
            "the withheld canvas follows its display; the other display is untouched")
    }

    func testAWithheldCanvasWithNothingLeftIsNotEnumerated() {
        // A canvas can exist with neither an occupant nor a chapter (all
        // its windows restored): it is not this display's second surface.
        directory.withCanvas(withheld) { $0.notice = "Untiled." }

        XCTAssertEqual(directory.visibleKeys(), [identified, otherIdentified])
    }

    func testActionKeyFallsBackToTheWithheldCanvasOnlyWhileTheNamedOneIsEmpty() {
        XCTAssertEqual(
            directory.actionKey(for: Self.screen.id), identified,
            "an empty named canvas is still the display's key")

        holdAChapter(withheld)
        XCTAssertEqual(
            directory.actionKey(for: Self.screen.id), withheld,
            "a display action reaches the withheld canvas while the named one is empty")

        holdAChapter(identified)
        XCTAssertEqual(
            directory.actionKey(for: Self.screen.id), identified,
            "the named canvas wins once it holds anything")
    }

    func testNoDisplaysEnumeratesRememberedCanvasesInDisplayThenSpaceOrder() {
        screens = []
        directory.withCanvas(
            TilingSpaceKey(screen: Self.otherScreen.id, space: nil)) { _ in }
        directory.withCanvas(
            TilingSpaceKey(screen: Self.screen.id, space: SpaceID(rawValue: 102))) { _ in }
        directory.withCanvas(identified) { _ in }

        XCTAssertEqual(
            directory.visibleKeys(),
            [
                identified,
                TilingSpaceKey(screen: Self.screen.id, space: SpaceID(rawValue: 102)),
                TilingSpaceKey(screen: Self.otherScreen.id, space: nil),
            ],
            "headless falls back to every remembered canvas, display then Space")
    }

    func testFocusTrackingReportsOnlyWhenTheCanvasMoves() {
        XCTAssertTrue(directory.noteFocusedKey(identified), "the first answer reports")
        XCTAssertFalse(directory.noteFocusedKey(identified), "a move within one canvas is silent")
        XCTAssertTrue(directory.noteFocusedKey(withheld))
        XCTAssertFalse(directory.noteFocusedKey(withheld))
    }

    func testVisibilityTreatsAWithheldCanvasAsTheDisplayTheUserSees() {
        XCTAssertTrue(directory.isVisible(identified))
        XCTAssertTrue(directory.isVisible(withheld), "a withheld Space id is not a hidden canvas")

        activeSpaces[Self.displayID] = SpaceID(rawValue: 999)
        XCTAssertFalse(directory.isVisible(identified), "another Space is hidden")

        activeSpaces = [:]
        XCTAssertTrue(
            directory.isVisible(identified),
            "an unknown active Space is unknown, not hidden")

        screens = [Self.otherScreen]
        XCTAssertFalse(
            directory.isVisible(withheld),
            "an absent display is never visible, withheld or not")
    }
}
