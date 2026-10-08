import CoreGraphics
@testable import tiled

/// One `TilingSpace` under test: fake gateway, injected bounds, and a
/// drag tracker wired to the same canvas. `TilingSpaceTests` and the
/// matrix replay drive the canvas through this seam instead of copying
/// the placement pipeline into the test.
///
/// No controller, no AX, no live screen: every frame write lands in the
/// fake gateway, every rect derives from `bounds`, and every action is
/// observed through the canvas's own state, notices, and outcomes. The
/// expectation owner is wired exactly like the controller's: late checks
/// are captured for manual firing.
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
    private(set) var tracker: DragTracker!
    private(set) var expectations: WriteExpectations!
    /// Late silent-ignore checks captured from the injectable scheduler,
    /// in scheduling order.
    private(set) var checks: [() -> Void] = []
    /// Canvases a deferred write marked stale.
    private(set) var staleMarks: [TilingSpaceKey] = []

    init() {
        expectations = WriteExpectations(
            gateway: gateway,
            isVisible: { [weak self] _ in self?.canvasVisible ?? true },
            markStale: { [weak self] in self?.staleMarks.append($0) },
            scheduleCheck: { [weak self] fire in
                self?.checks.append(fire)
                return {}
            },
            liveFrameOf: { [weak self] id in
                guard let self, let handle = self.handles[id] else { return nil }
                return self.gateway.frame(of: handle)
            },
            notePushed: { [weak self] id, target in
                self?.tracker.notePushed(id, target)
            })
        tracker = DragTracker(
            expectations: expectations,
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
            apply: { _, _ in })
    }

    /// The collaborators one canvas action needs. A fresh context is
    /// built per action, like the coordinator does.
    func context() -> TilingSpace.Context {
        TilingSpace.Context(
            gateway: gateway,
            tracker: tracker,
            expectations: expectations,
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

    /// One chapter group through the primitive the controller drives:
    /// the canvas restores and reports, narration stays controller-side.
    func restoreChapter(_ group: [EvictedWindow]) -> TilingSpace.ChapterRestore {
        space.restoreChapter(group, context: context())
    }
}
