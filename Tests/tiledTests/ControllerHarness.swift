import CoreGraphics
import Foundation
@testable import tiled

/// One `TilingController` under test: the injected display literal(s), the
/// fake gateway, the controller built over them, and the canvas actions
/// resolve. A suite keeps its own scenario and assertions; this seam only
/// removes the repeated fixture that had started to drift (one suite tiled
/// against `NSScreen.screens` while declaring an injected display it never
/// passed).
///
/// The screen list lives in a reference box so a suite can plug or unplug a
/// display mid-test without rebuilding the controller, and the drag-end,
/// convergence, and prune schedulers capture their closures instead of
/// touching the runloop. Every default is the deterministic test choice:
/// no prune timer, immediate death confirmation, and schedulers that only
/// record what they were asked to fire.
final class ControllerHarness {
    /// The provider's backing store: mutating `screens` is visible to the
    /// controller's next read, matching `NSScreen.screens`'s live answer.
    private final class ScreenValues {
        var values: [ScreenInfo]

        init(_ values: [ScreenInfo]) {
            self.values = values
        }
    }

    /// One scheduler's captured work. A reference type so the scheduler
    /// closure can append after `init` while suites read the same list.
    private final class FireLog {
        var fires: [() -> Void] = []
        var cancels = 0
    }

    private let screenValues: ScreenValues
    private let dragEndLog = FireLog()
    private let verifyLog = FireLog()
    private let pruneLog = FireLog()

    let gateway: FakeWindowGateway
    let controller: TilingController

    /// The displays actions resolve against. A suite may replace the list
    /// to simulate a display change; the controller sees the new value on
    /// its next action.
    var screens: [ScreenInfo] {
        get { screenValues.values }
        set { screenValues.values = newValue }
    }

    /// Drag-end fires captured from the injectable scheduler, in order.
    var dragEndFires: [() -> Void] {
        get { dragEndLog.fires }
        set { dragEndLog.fires = newValue }
    }

    /// Convergence-check fires captured from the injectable scheduler.
    var verifyFires: [() -> Void] {
        get { verifyLog.fires }
        set { verifyLog.fires = newValue }
    }

    /// How many scheduled verifications were cancelled (superseded).
    var verifyCancels: Int { verifyLog.cancels }

    /// Prune ticks captured from the injectable scheduler. A suite fires
    /// one instead of waiting out the production interval.
    var pruneFires: [() -> Void] {
        get { pruneLog.fires }
        set { pruneLog.fires = newValue }
    }

    /// The canvas the focused display tiles onto: reads go through the
    /// same accessor actions do.
    var canvas: TilingSpace {
        controller.canvas(for: controller.focusedTilingSpace)
    }

    init(
        screens: [ScreenInfo],
        gateway: FakeWindowGateway = FakeWindowGateway(),
        activeSpaces: [CGDirectDisplayID: SpaceID]? = nil,
        pruneInterval: TimeInterval? = nil,
        scheduleDragEnd: DragTracker.DragEndScheduler? = nil,
        scheduleVerify: DragTracker.DragEndScheduler? = nil,
        schedulePrune: TilingController.PruneScheduler? = nil,
        deathConfirmation: TimeInterval = 0,
        now: @escaping () -> Date = Date.init,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        let values = ScreenValues(screens)
        let dragEnd = dragEndLog
        let verify = verifyLog
        let prune = pruneLog
        screenValues = values
        self.gateway = gateway
        if let activeSpaces {
            gateway.activeSpaces = activeSpaces
        }
        controller = TilingController(
            gateway: gateway,
            pruneInterval: pruneInterval,
            scheduleDragEnd: scheduleDragEnd ?? { fire in
                dragEnd.fires.append(fire)
                return {}
            },
            scheduleVerify: scheduleVerify ?? { fire in
                verify.fires.append(fire)
                return { verify.cancels += 1 }
            },
            schedulePrune: schedulePrune ?? { _, fire in
                prune.fires.append(fire)
                return {}
            },
            screens: { values.values },
            deathConfirmation: deathConfirmation,
            now: now,
            uptime: uptime)
    }

    /// Hands a fresh window to the gateway and focuses it, the setup every
    /// controller suite repeats before an action.
    @discardableResult
    func addFocusedWindow(
        frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
        appName: String? = "TestApp"
    ) -> WindowHandle {
        let handle = gateway.addWindow(frame: frame, appName: appName)
        gateway.focused = handle
        return handle
    }
}
