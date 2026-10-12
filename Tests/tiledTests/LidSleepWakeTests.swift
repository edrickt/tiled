import XCTest
@testable import tiled

/// Lid close/open: the internal display disappears and returns. The
/// controller must keep the arrangement: windows stay tiled (slots and
/// frames) across the round trip. Driven through `TilingController`
/// with the fake gateway and a mutable screen provider, posting the
/// same notification the app observes.
final class LidSleepWakeTests: XCTestCase {
    private static let builtIn = ScreenInfo(
        id: ScreenID(rawValue: 1),
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055),
        name: "Built-in Retina Display")

    private var gateway: FakeWindowGateway!
    private var controller: TilingController!
    /// Mutable stand-in for NSScreen.screens: empty while the lid is
    /// closed, the built-in display when open.
    private var currentScreens: [ScreenInfo] = []
    /// Captured drag-end debounce fires (no runloop in tests).
    private var dragEndFires: [() -> Void] = []
    /// Captured convergence-check fires.
    private var verifyFires: [() -> Void] = []
    /// Injectable wall clock, advanced across a simulated sleep.
    private var wall: Date = Date(timeIntervalSince1970: 0)
    /// Injectable monotonic awake clock: frozen while the machine sleeps.
    private var awake: TimeInterval = 1000

    override func setUp() {
        super.setUp()
        gateway = FakeWindowGateway()
        currentScreens = [Self.builtIn]
        dragEndFires = []
        verifyFires = []
        wall = Date(timeIntervalSince1970: 0)
        awake = 1000
        controller = TilingController(
            gateway: gateway, pruneInterval: nil,
            scheduleDragEnd: { [self] fire in
                dragEndFires.append(fire)
                return {}
            },
            scheduleVerify: { [self] fire in
                verifyFires.append(fire)
                return {}
            },
            screens: { [self] in currentScreens })
    }

    /// Lets the drag-end debounce elapse, as it would on the runloop.
    private func fireDragEnds() {
        for fire in dragEndFires { fire() }
        dragEndFires.removeAll()
    }

    private func postScreenChange() {
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func addFocusedWindow(
        frame: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600)
    ) -> WindowHandle {
        let handle = gateway.addWindow(frame: frame)
        gateway.focused = handle
        return handle
    }

    // MARK: Loop 1: lid close with frames untouched, wake restores the display

    func testTilesSurviveLidCloseAndOpen() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)
        XCTAssertEqual(controller.canvas(for: Self.builtIn.id).state.occupant(of: .topLeft), 1)

        // Lid closed: the display vanishes; the system fires the
        // screen-parameters notification.
        currentScreens = []
        postScreenChange()

        // Lid opened: the display returns; another notification fires.
        currentScreens = [Self.builtIn]
        postScreenChange()

        XCTAssertEqual(
            controller.canvas(for: Self.builtIn.id).state.occupant(of: .topLeft), 1,
            "the window keeps its slot across lid close/open")
        XCTAssertEqual(
            gateway.frame(of: a),
            GridLayout().rect(for: .topLeft, in: Self.builtIn.visibleFrame),
            "the window sits on-grid after the lid reopens")
    }

    // MARK: Loop 2: the system rescales windows while the lid is closed
    // (display mode change on sleep/wake moves every window).

    func testTilesSurviveLidCloseWithSystemRescale() {
        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)

        currentScreens = []
        postScreenChange()

        // The system repositions windows while no display is attached
        // (mode switch): every frame shifts and shrinks.
        gateway.simulateSilentChange(a, to: CGRect(x: 40, y: 60, width: 700, height: 500))
        postScreenChange()

        currentScreens = [Self.builtIn]
        postScreenChange()

        XCTAssertEqual(
            controller.canvas(for: Self.builtIn.id).state.occupant(of: .topLeft), 1,
            "the window keeps its slot across lid close/open with a rescale")
        XCTAssertEqual(
            gateway.frame(of: a),
            GridLayout().rect(for: .topLeft, in: Self.builtIn.visibleFrame),
            "the window sits on-grid after the lid reopens")
    }

    // MARK: Loop 3: clamshell — an external display stays attached, so
    // macOS moves the built-in display's windows onto it while the lid
    // is closed. Those moves arrive as window-change events.

    func testTilesSurviveClamshellLidClose() {
        let external = ScreenInfo(
            id: ScreenID(rawValue: 2),
            frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 1920, y: 25, width: 2560, height: 1415),
            name: "External Display")
        currentScreens = [Self.builtIn, external]

        let a = addFocusedWindow()
        controller.handle(slot: .topLeft)
        XCTAssertEqual(controller.canvas(for: Self.builtIn.id).state.occupant(of: .topLeft), 1)

        // Lid closed: built-in vanishes; the system relocates its
        // windows onto the external display (two streamed ticks, like
        // a real relocation).
        currentScreens = [external]
        postScreenChange()
        gateway.simulateChange(a, to: CGRect(x: 2120, y: 160, width: 800, height: 600))
        gateway.simulateChange(a, to: CGRect(x: 2200, y: 200, width: 800, height: 600))
        fireDragEnds()

        // Lid opened: built-in returns; the system moves the window back.
        currentScreens = [Self.builtIn, external]
        postScreenChange()
        gateway.simulateChange(a, to: CGRect(x: 100, y: 100, width: 800, height: 600))
        gateway.simulateChange(a, to: CGRect(x: 100, y: 100, width: 800, height: 600))
        fireDragEnds()

        XCTAssertEqual(
            controller.canvas(for: Self.builtIn.id).state.occupant(of: .topLeft), 1,
            "the window keeps its slot across a clamshell lid cycle")
    }

    // MARK: Loop 4: a pending death must not ride out a sleep

    func testPendingDeathDoesNotConfirmAcrossASleep() {
        // The confirmation window measures the window's absence, not wall
        // time: eight sleeping hours are not eight seconds of observation.
        // A wall clock lets the pending death left before the lid closed
        // confirm on the first post-wake tick, untiling a live window.
        let timed = TilingController(
            gateway: gateway, pruneInterval: nil,
            scheduleDragEnd: { [self] fire in
                dragEndFires.append(fire)
                return {}
            },
            scheduleVerify: { [self] fire in
                verifyFires.append(fire)
                return {}
            },
            screens: { [self] in currentScreens },
            deathConfirmation: 3,
            now: { [self] in wall },
            uptime: { [self] in awake })
        let a = addFocusedWindow()
        timed.handle(slot: .topLeft)
        gateway.probeDead.insert(a)

        // First sighting while awake: a maybe, never a release.
        timed.pruneDeadWindows()
        XCTAssertEqual(timed.canvas(for: Self.builtIn.id).state.occupant(of: .topLeft), 1)

        // The lid closes: eight wall-clock hours pass while the machine
        // sleeps, so the monotonic uptime clock does not move. The first
        // post-wake tick must not read them as dead time.
        wall = wall.addingTimeInterval(8 * 60 * 60)
        timed.pruneDeadWindows()
        XCTAssertEqual(
            timed.canvas(for: Self.builtIn.id).state.occupant(of: .topLeft), 1,
            "sleeping hours must not count toward death confirmation")

        // The machine is awake for the full confirmation interval: now
        // the sustained dead reading confirms and releases the slot.
        awake += 3
        wall = wall.addingTimeInterval(3)
        timed.pruneDeadWindows()
        XCTAssertNil(
            timed.canvas(for: Self.builtIn.id).state.occupant(of: .topLeft),
            "a window still dead after a full awake interval is pruned")
    }

    func testConfirmedDeathStillPrunesWhileAwake() {
        // The mirror of the sleep case: with the machine staying awake, a
        // window that keeps reading dead confirms after its interval. The
        // sleep-proof clock must not disable ordinary death detection.
        let timed = TilingController(
            gateway: gateway, pruneInterval: nil,
            scheduleDragEnd: { [self] fire in
                dragEndFires.append(fire)
                return {}
            },
            scheduleVerify: { [self] fire in
                verifyFires.append(fire)
                return {}
            },
            screens: { [self] in currentScreens },
            deathConfirmation: 3,
            uptime: { [self] in awake })
        let a = addFocusedWindow()
        timed.handle(slot: .topLeft)
        gateway.probeDead.insert(a)

        timed.pruneDeadWindows()
        XCTAssertEqual(
            timed.canvas(for: Self.builtIn.id).state.occupant(of: .topLeft), 1,
            "the first sighting only marks")

        awake += 3
        timed.pruneDeadWindows()
        XCTAssertNil(
            timed.canvas(for: Self.builtIn.id).state.occupant(of: .topLeft),
            "death confirmed after a full awake interval releases the slot")
    }
}
