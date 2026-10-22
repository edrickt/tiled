import CoreGraphics
import XCTest

@testable import tiled

/// Characterization of the surfaces that read the visible canvases before
/// `CanvasDirectory` owns them. A display can hold two canvases at once:
/// the identified Space and the per-display fallback it tiled on while
/// the window server withheld the Space id. These tests pin which canvas
/// each surface names, including the deliberate disagreement between the
/// manage list (both canvases) and a display-scoped action (the identified
/// one once it holds anything).
final class CanvasSurfaceTests: XCTestCase {
    private static let displayID: CGDirectDisplayID = 42
    private static let screen = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        name: "Display 1",
        displayID: displayID)
    private static let namedSpace = SpaceID(rawValue: 101)

    private var gateway: FakeWindowGateway!
    private var controller: TilingController!
    private var withheld: TilingSpaceKey { TilingSpaceKey(screen: Self.screen.id, space: nil) }
    private var named: TilingSpaceKey {
        TilingSpaceKey(screen: Self.screen.id, space: Self.namedSpace)
    }

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            screens: { [Self.screen] }, deathConfirmation: 0)
    }

    @discardableResult
    private func addFocusedWindow(
        frame: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600)
    ) -> WindowHandle {
        let handle = gateway.addWindow(frame: frame)
        gateway.focused = handle
        return handle
    }

    /// The window tiles onto the display's withheld canvas while the
    /// Space table answers nothing; naming the Space afterwards must not
    /// strand it.
    func testWithheldFallbackResolvesTheDisplayCanvasUntilTheNamedSpaceHoldsAnything() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)
        XCTAssertEqual(
            controller.canvas(for: withheld).state.occupant(of: .topLeft), a.id,
            "the window tiled onto the display's withheld canvas")

        gateway.activeSpaces = [Self.displayID: Self.namedSpace]

        XCTAssertEqual(
            controller.canvas(for: Self.screen.id).state.occupant(of: .topLeft), a.id,
            "a display action resolves the withheld canvas while the named one is empty")
        XCTAssertEqual(
            controller.focusedTilingSpace, withheld,
            "focus resolves the owning canvas, never a same-display neighbour")
        XCTAssertEqual(
            controller.allTiledWindowsInfo().map(\.id), [a.id],
            "the manage list still reaches the withheld canvas")

        controller.untileAll()
        XCTAssertNil(
            controller.canvas(for: withheld).state.occupant(of: .topLeft),
            "Untile All reaches the withheld canvas")
    }

    /// Once the named canvas holds anything, a display-scoped action
    /// resolves it, while the manage list keeps listing both canvases.
    /// That disagreement is deliberate for now: the menu dedupes rows by
    /// window, so it must see the withheld canvas even when a bulk action
    /// would not touch it.
    func testManageListListsBothCanvasesWhileDisplayActionsUseTheNamedOne() {
        let withheldWindow = addFocusedWindow()
        controller.handle(slot: .topLeft)
        gateway.activeSpaces = [Self.displayID: Self.namedSpace]
        let namedWindow = addFocusedWindow()
        controller.handle(slot: .topLeft)

        XCTAssertEqual(
            controller.canvas(for: withheld).state.occupant(of: .topLeft), withheldWindow.id)
        XCTAssertEqual(
            controller.canvas(for: named).state.occupant(of: .topLeft), namedWindow.id)
        XCTAssertEqual(
            controller.canvas(for: Self.screen.id).state.occupant(of: .topLeft),
            namedWindow.id,
            "the display action resolves the named canvas once it holds anything")
        XCTAssertEqual(
            controller.allTiledWindowsInfo().map(\.id),
            [namedWindow.id, withheldWindow.id],
            "the manage list sources the named canvas first, then the withheld fallback")

        controller.untileAll()
        XCTAssertNil(
            controller.canvas(for: named).state.occupant(of: .topLeft),
            "Untile All dissolves the canvas it resolved")
        XCTAssertEqual(
            controller.canvas(for: withheld).state.occupant(of: .topLeft), withheldWindow.id,
            "the withheld canvas survives a display action it did not name")
        XCTAssertEqual(
            controller.allTiledWindowsInfo().map(\.id), [withheldWindow.id],
            "the withheld canvas still reaches the manage list")
    }

    /// The focus-scoped canvas is the display's action key, not the
    /// focused window's owning canvas: once the named canvas holds
    /// anything, the glyph and menu follow it even while the focused
    /// window lives on the withheld canvas. A request from that window
    /// still resolves its own canvas. This is the disagreement the
    /// directory must preserve, not unify.
    func testFocusScopedCanvasUsesTheDisplayActionKeyNotTheWindowsOwnCanvas() {
        let withheldWindow = addFocusedWindow()
        controller.handle(slot: .topLeft)
        gateway.activeSpaces = [Self.displayID: Self.namedSpace]
        let namedWindow = addFocusedWindow()
        controller.handle(slot: .topLeft)

        gateway.focused = namedWindow
        XCTAssertEqual(controller.focusedTilingSpace, named)

        gateway.focused = withheldWindow
        XCTAssertEqual(
            controller.focusedTilingSpace, named,
            "the glyph follows the display action key, not the window's canvas")
        XCTAssertEqual(
            controller.canvas(for: withheld).state.occupant(of: .topLeft), withheldWindow.id,
            "the window still owns its record on the withheld canvas")

        controller.handle(slot: .topRight)
        XCTAssertEqual(
            controller.canvas(for: withheld).state.occupant(of: .topRight), withheldWindow.id,
            "a request from the window resolves the canvas that owns it")
        XCTAssertEqual(
            controller.canvas(for: named).state.occupant(of: .topLeft), namedWindow.id,
            "the named canvas is untouched by the window's own request")
    }
}
