import CoreGraphics
import Foundation
@testable import tiled

/// One `TilingSpace` under test: fake gateway, injected bounds, and a
/// drag tracker wired to the same canvas. `TilingSpaceTests` and the
/// matrix replay drive the canvas through this seam instead of copying
/// the placement pipeline into the test.
///
/// No controller, no AX, no live screen: every frame write lands in the
/// fake gateway, every rect derives from `bounds`, and every action is
/// observed through the canvas's own state, notices, and outcomes.
final class TilingSpaceHarness {
    let gateway = FakeWindowGateway()
    var space = TilingSpace()
    var handles: [WindowID: WindowHandle] = [:]
    var nextID: WindowID = 1
    /// Whether the injected visibility policy sees the canvas. Hidden
    /// canvas tests flip this; everyone else writes as on a visible one.
    var canvasVisible = true
    /// Injected bounds: every placement, reflow, and expand derives its
    /// target from this rect, never a live `NSScreen`.
    var bounds = CGRect(x: 0, y: 0, width: 1600, height: 1200)
    /// Injected clock backing the animator's progress. Tests advance it
    /// one step at a time and fire the captured steps by hand, so glides
    /// are deterministic and never touch the runloop.
    var now = Date()
    /// Whether moves glide. Off by default: the placement suite asserts
    /// instant landings; animation tests opt in and drive the steps.
    var animationEnabled = false
    /// Whether the injected Reduce Motion provider says snap. Read live
    /// per move, like the real OS setting.
    var reduceMotion = false
    private(set) var tracker: DragTracker!
    private(set) var writer: FrameWriter!
    private(set) var animator: Animator!
    /// A scheduled fire awaiting a manual trigger: an animator step or a
    /// tracker drag end. The scheduler's canceller nils a superseded
    /// fire, so a retargeted glide's stale step never fires against the
    /// newer glide, and a continued drag's stale drag end never ends it.
    private final class StepBox { var fire: (() -> Void)? }
    private var pendingSteps: [StepBox] = []
    /// Drag ends the tracker's debounce scheduled (latest wins per drag;
    /// superseded fires are cancelled).
    private var pendingDragEnds: [StepBox] = []

    /// Whether any glide has a step waiting to fire.
    var hasPendingSteps: Bool { pendingSteps.contains { $0.fire != nil } }

    /// Fires every drag end the tracker scheduled. Superseded ends are
    /// already cancelled; the live one fires.
    func fireDragEnd() {
        let boxes = pendingDragEnds
        pendingDragEnds = []
        for box in boxes { box.fire?() }
    }

    init() {
        animator = Animator(
            now: { [weak self] in self?.now ?? Date() },
            scheduleStep: { [weak self] fire in
                let box = StepBox()
                box.fire = fire
                self?.pendingSteps.append(box)
                return { box.fire = nil }
            },
            isEnabled: { [weak self] in self?.animationEnabled ?? false },
            reduceMotion: { [weak self] in self?.reduceMotion ?? false },
            frameOf: { [weak self] handle in self?.gateway.frame(of: handle) },
            setFrame: { [weak self] handle, frame in
                self?.gateway.setFrame(handle, to: frame) ?? false
            })
        tracker = DragTracker(
            context: DragTracker.Context(
                slotOf: { [weak self] in self?.space.state.slot(of: $0) },
                frameOf: { [weak self] in
                    guard let self, let handle = self.handles[$0] else { return nil }
                    return self.gateway.frame(of: handle)
                        ?? self.space.records[$0]?.preTileFrame
                },
                boundsOf: { [weak self] in self?.bounds ?? $0 },
                occupants: { [weak self] in self?.space.state.occupants ?? [:] }),
            gridProvider: DragTracker.GridProvider(
                grid: { [weak self] _ in self?.space.grid ?? GridLayout() },
                setGrid: { [weak self] updated, _ in self?.space.grid = updated }),
            apply: { [weak self] rects, excluding in
                self?.publishFromTracker(rects: rects, excluding: excluding)
            },
            scheduleDragEnd: { [weak self] fire in
                let box = StepBox()
                box.fire = fire
                self?.pendingDragEnds.append(box)
                return { box.fire = nil }
            })
        writer = FrameWriter(
            gateway: gateway,
            animator: animator,
            isVisible: { [weak self] _ in self?.canvasVisible ?? true },
            boundsOf: { [weak self] in self?.bounds ?? $0 },
            markStale: { _ in },
            markExpected: { [weak self] id, target in
                self?.tracker.markExpected(id, target)
            },
            scheduleCheck: { _, _ in },
            onLandingFailed: { [weak self] id, _ in
                guard let self else { return }
                let name = self.handles[id].flatMap { self.gateway.appName(of: $0) }
                    ?? "That window"
                self.space.discard(
                    window: id, refusing: TilingSpace.refusalMessage(windowName: name),
                    context: self.context())
            },
            log: { _ in })
    }

    /// Advances the injected clock one animation step and fires every
    /// step the animator scheduled for this generation.
    func step() {
        now = now.addingTimeInterval(Animator.stepInterval)
        let boxes = pendingSteps
        pendingSteps = []
        for box in boxes { box.fire?() }
    }

    /// Fires scheduled steps until every glide has landed. Bounded so a
    /// stuck glide fails the test's later assertions instead of hanging.
    func settleAnimations(maxSteps: Int = 64) {
        var fired = 0
        while hasPendingSteps, fired < maxSteps {
            step()
            fired += 1
        }
    }

    /// The collaborators one canvas action needs. A fresh context is
    /// built per action, like the coordinator does.
    func context() -> TilingSpace.Context {
        TilingSpace.Context(
            gateway: gateway,
            frameWriter: writer,
            tracker: tracker,
            animator: animator,
            boundsOf: { [weak self] in self?.bounds ?? $0 },
            space: .displayless,
            allocateID: { [weak self] _ in
                guard let self else { return 0 }
                let id = self.nextID
                self.nextID += 1
                return id
            },
            log: { _ in })
    }

    /// Hands a fresh window to the canvas and returns its id.
    @discardableResult
    func addWindow(frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)) -> WindowID {
        let id: WindowID = nextID
        nextID += 1
        let handle = gateway.addWindow(frame: frame)
        handles[id] = handle
        space.attach(id, handle: handle)
        return id
    }

    func handle(of id: WindowID) -> WindowHandle? { handles[id] }

    func frame(of id: WindowID) -> CGRect? {
        handles[id].flatMap { gateway.frame(of: $0) }
    }

    /// The rect the canvas would write for `slot` under its own grid and
    /// the injected bounds.
    func rect(_ slot: Slot, in bounds: CGRect? = nil) -> CGRect {
        space.grid.rect(for: slot, in: bounds ?? self.bounds)
    }

    /// The coordinator's handover: resolve the requester's record before
    /// an action. A window released by an eviction re-attaches with a
    /// fresh record, exactly as `requesterAndCanvas` hands it over.
    func attachRequester(_ id: WindowID) {
        if let handle = handles[id] {
            space.attach(id, handle: handle)
        }
    }

    /// The coordinator's re-resolution after a release: the same live
    /// handle comes back under a fresh id with a fresh record, exactly as
    /// `windowID(for:)` allocates one once the old record is gone.
    @discardableResult
    func reattach(_ id: WindowID) -> WindowID {
        guard let handle = handles[id] else { return id }
        let fresh: WindowID = nextID
        nextID += 1
        handles[fresh] = handle
        space.attach(fresh, handle: handle)
        return fresh
    }

    /// Runs one already-decided plan through the canvas's execute seam.
    @discardableResult
    func run(_ decision: TilePlan, requester: WindowID, slot: Slot) -> TilingSpace.Outcome {
        attachRequester(requester)
        return space.execute(
            decision: decision, requester: requester, slot: slot, context: context())
    }

    /// Runs one placement request through the canvas (plan included).
    @discardableResult
    func apply(slot: Slot, requester: WindowID) -> TilingSpace.Outcome {
        attachRequester(requester)
        return space.apply(slot: slot, requester: requester, context: context())
    }

    /// One undo chapter through the canvas.
    func undo(snapshot: [EvictedWindow], requester: WindowID?) -> TilingSpace.UndoOutcome {
        space.undo(snapshot: snapshot, requester: requester, context: context())
    }

    /// Routes the tracker's coalesced pushes into the canvas's publish
    /// path, exactly as the controller's `publishRects` does. The tracker's
    /// releases glide when animation is enabled. The tracker dispatches
    /// onto the main queue; tests wait for the runloop tick.
    private func publishFromTracker(rects: [WindowID: CGRect], excluding: WindowID?) {
        space.publish(rects: rects, excluding: excluding, context: context(), animated: true)
    }
}
