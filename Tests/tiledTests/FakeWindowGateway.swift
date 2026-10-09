import CoreGraphics
@testable import tiled

/// In-memory `WindowGateway`: the second adapter behind the seam.
///
/// Windows are plain frames in a dictionary; observation handlers fire
/// synchronously via `simulateChange`. Refusals, probe failures, and
/// registration failures are scripted per handle; deaths via `kill` or
/// via the real death standard judging those scripts. No AX, no AppKit,
/// no runloop.
final class FakeWindowGateway: WindowGateway {
    private var nextID = 1
    struct Window {
        var frame: CGRect
        var alive = true
        var refuseNextWrites = 0
        var appName: String?
    }
    private(set) var windows: [WindowHandle: Window] = [:]
    private var changeHandlers: [WindowHandle: () -> Void] = [:]
    private var destroyedHandlers: [WindowHandle: () -> Void] = [:]
    /// Handles in issuance order (stable ids for tests).
    private(set) var issued: [WindowHandle] = []

    var isTrusted = true

    func registerAccessibilityInterest() {}
    /// Handles whose writes report success but never change the frame:
    /// the dominant real-world refusal shape (an app that ignores AX
    /// resizes while returning success).
    var silentIgnore: Set<WindowHandle> = []
    /// Whether `focus` makes `focusedWindow` return the focused handle.
    /// The real adapter only requests activation: the system may ignore
    /// it, and the next focus query answers with whatever actually has
    /// focus. Off, focus requests are recorded but the environment keeps
    /// its own focus (the fidelity mode for that divergence).
    var focusChangesFocused = true
    /// The frame a successful write actually applies. Real apps can
    /// clamp or round the requested rect while still reporting success,
    /// so the live frame can differ from the target. Identity by default.
    var writtenFrame: (WindowHandle, CGRect) -> CGRect = { _, target in target }
    /// Handles whose size write is refused while the position write still
    /// lands: one half-apply shape (the origin moves, the call reports
    /// false). The fake models the app's per-message refusals; the
    /// put-back runs in the shared `AXWrite.pushFrame` policy below.
    var refuseSizeWrites: Set<WindowHandle> = []
    /// Handles whose position write is refused while the size write still
    /// lands: the mirror half-apply shape — the app resizes the window at
    /// its old origin and reports false. Same split as above: refusals
    /// modelled here, the put-back in the shared policy.
    var refusePositionWrites: Set<WindowHandle> = []
    /// Every frame write the adapter applied, in order — one entry per
    /// write that touched the frame (a half-applied pair records the
    /// frame the put-back policy left the window in). Lets tests pin
    /// "a no-op request issues zero writes" instead of only the
    /// resulting frame.
    private(set) var writes: [(handle: WindowHandle, frame: CGRect)] = []
    /// Handles the controller has released. Only confirmed death may
    /// release: an untiled or evicted window must keep its element so
    /// undo and re-tiling can reuse the stored handle.
    private(set) var releaseCalls: [WindowHandle] = []

    @discardableResult
    func addWindow(frame: CGRect, appName: String? = "TestApp") -> WindowHandle {
        let handle = WindowHandle(id: nextID)
        nextID += 1
        windows[handle] = Window(frame: frame, appName: appName)
        issued.append(handle)
        zOrder.append(handle)
        return handle
    }

    /// Raise calls in order (the controller's z-order side effects).
    private(set) var raiseCalls: [WindowHandle] = []
    /// Window z-order, back to front. `addWindow` appends (newest on
    /// top, like the real WindowServer); `raise` moves to the front.
    private(set) var zOrder: [WindowHandle] = []

    /// The fake has no focus model: tests declare the focused window.
    var focused: WindowHandle?
    /// Focus requests issued, in order: tests assert focus side effects.
    private(set) var focusCalls: [WindowHandle] = []

    // MARK: WindowGateway

    func focusedWindow() -> WindowHandle? {
        guard let focused, windows[focused]?.alive == true else { return nil }
        return focused
    }

    func frame(of handle: WindowHandle) -> CGRect? {
        guard let window = windows[handle], window.alive else { return nil }
        if hideFrames.contains(handle) { return nil }
        lastFrames[handle] = window.frame
        return window.frame
    }

    @discardableResult
    func setFrame(_ handle: WindowHandle, to frame: CGRect) -> Bool {
        guard var window = windows[handle], window.alive else { return false }
        if silentIgnore.contains(handle) { return true }
        if window.refuseNextWrites > 0 {
            window.refuseNextWrites -= 1
            windows[handle] = window
            return false
        }
        // The pair runs through the production write policy
        // (`AXWrite.pushFrame`) — the same glue the live adapter drives
        // its two AX messages with — so the half-apply put-back is
        // pinned end-to-end here, not reimplemented in the fake. The
        // scripted refusals answer `.failure` (a permanent refusal), so
        // the policy's retry takes one attempt per write.
        let applied = writtenFrame(handle, frame)
        var touched = false
        let error = LiveWindowGateway.AXWrite.pushFrame(
            position: applied.origin, size: applied.size,
            readPosition: { self.windows[handle]?.frame.origin },
            readSize: { self.windows[handle]?.frame.size },
            writePosition: { origin in
                guard !self.refusePositionWrites.contains(handle) else { return .failure }
                self.windows[handle]?.frame.origin = origin
                touched = true
                return .success
            },
            writeSize: { size in
                guard !self.refuseSizeWrites.contains(handle) else { return .failure }
                self.windows[handle]?.frame.size = size
                touched = true
                return .success
            },
            sleep: { _ in })
        // One entry per write that touched the frame: a half-applied
        // pair's entry shows the frame the policy left the window in,
        // while a write the app refused outright touches nothing and a
        // silently ignored one applies nothing.
        if touched, let end = windows[handle]?.frame {
            writes.append((handle, end))
        }
        return error == nil
    }

    func release(_ handle: WindowHandle) {
        releaseCalls.append(handle)
        changeHandlers[handle] = nil
        destroyedHandlers[handle] = nil
        // Like live's release, the element drops: later frame reads go
        // dark and liveness reads dead, so an undo-on-a-released-handle
        // shape cannot pass against a window the fake kept around.
        windows[handle] = nil
        lastFrames[handle] = nil
    }

    /// Handles whose liveness probe reports unknown (a busy app that
    /// cannot answer the probe): alive for every other purpose, never
    /// pruned.
    var busy: Set<WindowHandle> = []
    /// Handles scripted to read dead while the window lives: the
    /// controller's confirmation window turns one dead reading into a
    /// maybe, so tests drive the transient-then-recovery shape without
    /// waiting on a real lid cycle.
    var probeDead: Set<WindowHandle> = []
    /// Handles whose frame reads fail while the window lives: the same
    /// lid-close transient on the frame-read path.
    var hideFrames: Set<WindowHandle> = []
    /// Handles whose liveness probe fails while the window lives: the
    /// lid-close transient on the held element. The verdict is the real
    /// death standard's — the failed probe is corroborated against the
    /// owning app's window list and the frame baseline, the same
    /// assembly the live gateway judges with — so tests can drive the
    /// non-happy shapes (element churn, geometric absence, undeterminable
    /// membership) without scripting the verdict.
    var probeFailures: Set<WindowHandle> = []
    /// Handles whose change notifications could not be registered: the
    /// OS delivers neither moves nor destroys for them. `observe` keeps
    /// the handlers (the controller held up its end) but nothing
    /// simulates through — the failed registration's observable shape.
    var registrationFailures: Set<WindowHandle> = []
    /// Last read frame per handle: the frame baseline the geometric
    /// death confirmation matches against, with the live gateway's
    /// staleness rules — seeded when observing starts, refreshed by
    /// frame reads (and successful probes), never by a move nobody
    /// notified. A stale one condemns a moved window; that hazard is
    /// deliberately modelled, not smoothed over.
    private var lastFrames: [WindowHandle: CGRect] = [:]
    /// Synthetic pid per owning app name: the death standard asks each
    /// app once per pass and judges its windows against that answer.
    private var pidsByApp: [String: pid_t] = [:]
    private var appsByPID: [pid_t: String] = [:]
    private var nextPID: pid_t = 100

    /// Every liveness pass requested through the seam, in order. Pins
    /// the one-pass contract: a prune pass must ask once for all of its
    /// records, not once per record.
    private(set) var livenessPasses: [[WindowHandle]] = []

    func liveness(of handles: [WindowHandle]) -> [WindowHandle: Liveness] {
        livenessPasses.append(handles)
        var verdicts: [WindowHandle: Liveness] = [:]
        var probes: [LiveWindowGateway.ProbedWindow] = []
        for handle in handles {
            guard let window = windows[handle] else {
                verdicts[handle] = .dead
                continue
            }
            if probeDead.contains(handle) { verdicts[handle] = .dead; continue }
            if !window.alive { verdicts[handle] = .dead; continue }
            if busy.contains(handle) { verdicts[handle] = .unknown; continue }
            let failed = probeFailures.contains(handle)
            probes.append(
                LiveWindowGateway.ProbedWindow(
                    handle: handle, pid: pid(of: handle),
                    error: failed ? .invalidUIElement : .success,
                    frame: failed || hideFrames.contains(handle) ? nil : window.frame))
        }
        // The same pass assembly the live adapter judges with — the
        // fake scripts the raw inputs (probe outcomes, window lists,
        // baselines) but never a verdict, so the death standard cannot
        // drift behind the seam. Successful probes refresh the baseline
        // here exactly as they do in production.
        let pass = LiveWindowGateway.livenessPass(
            probes: probes,
            baselines: lastFrames,
            appAnswer: { self.appWindowAnswer(for: $0) })
        lastFrames = pass.baselines
        verdicts.merge(pass.verdicts) { _, new in new }
        return verdicts
    }

    private func pid(of handle: WindowHandle) -> pid_t {
        let name = windows[handle]?.appName ?? ""
        if let pid = pidsByApp[name] { return pid }
        let pid = nextPID
        nextPID += 1
        pidsByApp[name] = pid
        appsByPID[pid] = name
        return pid
    }

    /// One owning app's answer for a liveness pass: the windows it still
    /// has, each listed with its current frame — nil for a listed frame
    /// that will not read (the lid-close shape). Closed and released
    /// windows are gone from the list, like live's.
    private func appWindowAnswer(for pid: pid_t) -> LiveWindowGateway.AppWindowAnswer {
        let name = appsByPID[pid] ?? ""
        let members = windows.filter { $0.value.alive && ($0.value.appName ?? "") == name }
        return LiveWindowGateway.AppWindowAnswer(
            processAlive: true,
            appWindowsError: .success,
            listedFrames: members.map { hideFrames.contains($0.key) ? nil : $0.value.frame })
    }

    func observe(
        _ handle: WindowHandle, onChange: @escaping () -> Void,
        onDestroyed: @escaping () -> Void
    ) {
        changeHandlers[handle] = onChange
        destroyedHandlers[handle] = onDestroyed
        // The geometric death check needs a baseline even for a window
        // whose frame was never read (live's `observe` seeds one).
        if lastFrames[handle] == nil, let frame = windows[handle]?.frame {
            lastFrames[handle] = frame
        }
    }

    private var focusChangeHandler: (() -> Void)?

    func observeFocusChanges(_ onChange: @escaping () -> Void) {
        focusChangeHandler = onChange
    }

    /// Test control: simulates the frontmost app's focused window moving.
    func simulateFocusChange() {
        focusChangeHandler?()
    }

    /// Mission Control Space currently shown per display. Empty means
    /// "unknown", so keys fall back to per-display behavior.
    var activeSpaces: [CGDirectDisplayID: SpaceID] = [:]

    func activeSpace(on display: CGDirectDisplayID) -> SpaceID? {
        activeSpaces[display]
    }

    private var spaceChangeHandler: (() -> Void)?

    func observeSpaceChanges(_ onChange: @escaping () -> Void) {
        spaceChangeHandler = onChange
    }

    /// Test control: simulates swiping to another Space on any display.
    /// Mutate `activeSpaces` first.
    func simulateSpaceChange() {
        spaceChangeHandler?()
    }

    func focus(_ handle: WindowHandle) {
        focusCalls.append(handle)
        if focusChangesFocused { focused = handle }
    }

    func raise(_ handle: WindowHandle) {
        raiseCalls.append(handle)
        if let index = zOrder.firstIndex(of: handle) {
            zOrder.remove(at: index)
            zOrder.append(handle)
        }
    }

    func appName(of handle: WindowHandle) -> String? {
        windows[handle]?.appName
    }

    // MARK: Test controls

    /// Moves the window as a user drag would, firing the change handler
    /// unless the registration failed — then the OS has nothing to
    /// deliver and only the frame moves.
    func simulateChange(_ handle: WindowHandle, to frame: CGRect) {
        windows[handle]?.frame = frame
        guard !registrationFailures.contains(handle) else { return }
        changeHandlers[handle]?()
    }

    /// Moves without firing (asserts echo suppression absorbed it).
    func simulateSilentChange(_ handle: WindowHandle, to frame: CGRect) {
        windows[handle]?.frame = frame
    }

    /// Test control: simulates the OS's `AXUIElementDestroyed`
    /// notification. `kill` first to model a window that is really gone;
    /// leave it alive to model element churn. A failed registration
    /// delivers nothing, destroys included.
    func simulateDestroyed(_ handle: WindowHandle) {
        guard !registrationFailures.contains(handle) else { return }
        destroyedHandlers[handle]?()
    }

    func kill(_ handle: WindowHandle) {
        windows[handle]?.alive = false
    }

    func refuseNextWrites(_ handle: WindowHandle, count: Int = 1) {
        windows[handle]?.refuseNextWrites = count
    }

    /// Clears the write log: tests assert about writes from here on.
    func clearWrites() {
        writes.removeAll()
    }

    func observedHandles() -> [WindowHandle] {
        Array(changeHandlers.keys)
    }
}
