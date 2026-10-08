import CoreGraphics
import Foundation

/// One owner for a frame push's whole life: the shared write policy
/// (off-Space deferral, no-op skip, refusal), the expectation armed before
/// the gateway call, the echo trail watched tick by tick, the late
/// convergence verdict, and the consequence a silent ignore pays. Also
/// owns where the window was meant to go (intent).
///
/// The drag loop consumes `classify` per gateway tick and keeps only drag
/// semantics (snapback, untile, `processMove`). Every frame write goes
/// through `write`, which states only where the window goes and what a
/// silent ignore means; the check is armed internally and per performed
/// write, so no write path can forget to verify itself.
///
/// Two things live per window here, deliberately separate:
/// - the armed expectation: the pushed frame plus its echo trail, cleared
///   by convergence, takeover, staleness, and `forget`;
/// - the intent: the last frame we wanted the window in. Intent outlives
///   both the echo entry and `forget`: undo chapters replay writes for
///   ids whose frames were restored out from under them, and diffing must
///   measure against where we were going, not where an echo left us.
final class WriteExpectations {
    /// One armed expectation: the pushed frame plus its echo trail.
    private struct ExpectedWrite {
        let frame: CGRect
        /// Last observed sum-of-edge-deltas from `frame`. Starts at infinity;
        /// only a strictly increasing distance means a user took over.
        var lastDistance: CGFloat
        /// Write time, or the consume moment once settled: bounds both
        /// the unapplied-write wait and the post-converge settle window.
        var date: Date
        /// True once a tick landed within tolerance: the write applied and
        /// the window is settling. Close ticks keep being swallowed for
        /// `settleWindow` so the animation tail is never mistaken for a
        /// drag; a tick beyond tolerance ends settling and processes live.
        var settled: Bool
    }

    /// One performed gateway write's classification.
    enum Result: Equatable {
        /// The gateway accepted the write.
        case written
        /// The live frame already matches the target: no write issued.
        case skippedNoOp
        /// The canvas is not the visible Space: no write issued, and the
        /// canvas is marked stale for the swipe back.
        case deferredOffSpace
        /// The gateway refused the write.
        case refused

        /// The write is on screen, or already correct: callers count
        /// both as a successful placement.
        var isAccepted: Bool { self == .written || self == .skippedNoOp }
    }

    /// What a silent ignore of this write means. Semantic tokens, not a
    /// check flag: call sites never say *whether* to verify (every
    /// performed write is), only what the app's silence has to undo.
    enum Consequence: Equatable {
        /// A layout write (placement, reflow, reassert, publish): a
        /// silent ignore releases the window and announces the standard
        /// refusal.
        case slotCommit
        /// A cover toggle (expand, collapse, retile): a silent ignore
        /// reverts the expanded record to its pre-write value - nil
        /// clears (expand), a frame restores (collapse and retile). The
        /// revert writes no frames.
        case coverToggle(revertTo: CGRect?)
    }

    /// Schedules the late convergence check and returns a canceller.
    typealias CheckScheduler = (@escaping () -> Void) -> () -> Void

    /// Delay before a performed write is judged converged or ignored.
    /// Past the stale-write window (no tick even approached the target),
    /// with margin for slow apps: animations settle in ~0.5s, so 3.5s of
    /// total silence means the app ignored the write, not that it is
    /// still animating.
    static let checkDelay: TimeInterval = 3.5

    /// Production check scheduler: one main-queue timer per performed write.
    static let scheduleCheckOnMain: CheckScheduler = { fire in
        let item = DispatchWorkItem(block: fire)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + WriteExpectations.checkDelay, execute: item)
        return { item.cancel() }
    }

    /// Armed expectations by window (echo suppression).
    private var expected: [WindowID: ExpectedWrite] = [:]
    /// Last frame we wanted each window in, written or not.
    private var intents: [WindowID: CGRect] = [:]
    /// Pending late checks by window: one per performed write, the newer
    /// superseding the older. The serial proves a firing closure belongs
    /// to the check still registered: a cancelled work item whose fire
    /// escapes judges nothing.
    private var checks: [WindowID: PendingCheck] = [:]
    private var checkSerial = 0

    /// One scheduled late check: its canceller and the consequence its
    /// write pays on a silent ignore.
    private struct PendingCheck {
        let serial: Int
        let cancel: () -> Void
        let consequence: Consequence
    }

    private static let echoTolerance: CGFloat = 32
    /// Writes within this distance of the window's current frame are
    /// no-ops: the app changes nothing and emits no AX notification, so
    /// marking them expected would leave an echo entry that never
    /// converges, and the late convergence check would read that silence
    /// as a silent ignore and evict an already-correct window. Skipped
    /// writes are success: state already agrees with the screen.
    static let noOpWriteTolerance: CGFloat = 1
    private static let staleWrite: TimeInterval = 3
    /// Post-converge settle window: macOS animation tails run ~0.2-0.5s,
    /// so 1s swallows them with margin while barely extending the blind
    /// prefix on a drag-out that starts the instant a write lands (a real
    /// drag escapes the moment it leaves the tolerance radius anyway,
    /// landing the splitter on its absolute position; only the untile
    /// distance, measured from the first escaped tick, can read short).
    private static let settleWindow: TimeInterval = 1

    private let gateway: WindowGateway
    /// Whether `space` is the canvas the user can see right now; a hidden
    /// canvas's write defers instead of pulling the window through the
    /// void.
    private let isVisible: (TilingSpaceKey) -> Bool
    /// Reports a canvas whose write deferred, for the re-assert on the
    /// swipe back.
    private let markStale: (TilingSpaceKey) -> Void
    /// Schedules one late convergence check; returns a canceller.
    /// Injectable so tests fire checks without waiting on real time.
    private let scheduleCheck: CheckScheduler
    /// The window's live frame, as the app reports it; unlike intent,
    /// which says where we wanted the window, this says where it actually
    /// is. The silent-ignore check consults it before calling total echo
    /// silence an ignore: apps that round frames to an internal grid can
    /// absorb a write without emitting anything.
    private let liveFrameOf: (WindowID) -> CGRect?
    /// Tells the drag loop a write is expected: the pushed target becomes
    /// its diff baseline and any in-progress drag is dropped.
    private let notePushed: (WindowID, CGRect) -> Void
    /// Pays a silent ignore's consequence; the body lives with the
    /// controller/canvas that owns the affected state.
    private let onConsequence: (WindowID, Consequence) -> Void
    /// Clock for echo-bookkeeping timestamps. Injectable so tests can
    /// fast-forward past the stale-write window without waiting on a
    /// real 3-second timeout.
    private let now: () -> Date
    private let log: (String) -> Void

    init(
        gateway: WindowGateway,
        isVisible: @escaping (TilingSpaceKey) -> Bool = { _ in true },
        markStale: @escaping (TilingSpaceKey) -> Void = { _ in },
        scheduleCheck: @escaping CheckScheduler = WriteExpectations.scheduleCheckOnMain,
        liveFrameOf: @escaping (WindowID) -> CGRect? = { _ in nil },
        notePushed: @escaping (WindowID, CGRect) -> Void = { _, _ in },
        onConsequence: @escaping (WindowID, Consequence) -> Void = { _, _ in },
        now: @escaping () -> Date = Date.init,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.gateway = gateway
        self.isVisible = isVisible
        self.markStale = markStale
        self.scheduleCheck = scheduleCheck
        self.liveFrameOf = liveFrameOf
        self.notePushed = notePushed
        self.onConsequence = onConsequence
        self.now = now
        self.log = log
    }

    // MARK: The write

    /// Writes one window's target frame under the shared policy: a
    /// target the window already holds is skipped (writing it would
    /// draw no echo, and a marked expectation that never converges
    /// reads as a silent ignore); otherwise the expectation is armed
    /// before the write, and one late convergence check is scheduled
    /// after the gateway accepted it. The consequence decides what that
    /// check pays if the app stayed silent. An app that reports success
    /// but applied a frame off the animation path to the target (a
    /// minimum-size clamp is the real shape) had the request overridden:
    /// the pre-write frame is restored and the write reads as refused.
    @discardableResult
    func write(
        _ id: WindowID, handle: WindowHandle, to target: CGRect,
        on space: TilingSpaceKey, consequence: Consequence
    ) -> Result {
        // A write to a canvas the user cannot see waits for the swipe
        // back: sizing an off-Space window can pull it onto the visible
        // Space. The mark re-asserts the canvas later.
        guard isVisible(space) else {
            markStale(space)
            log("write win\(id) deferred off-Space")
            return .deferredOffSpace
        }
        // No-op writes are skipped, not pushed: the app changes
        // nothing and emits no echo, so a marked expectation here
        // would never converge and the late check would misread an
        // already-correct window. The pre-write frame is also the
        // fallback the clamp guard restores to below.
        let live = gateway.frame(of: handle)
        if let live, Self.framesClose(live, target, tolerance: Self.noOpWriteTolerance) {
            log("write win\(id) no-op skip target=\(target)")
            return .skippedNoOp
        }
        noteExpected(id, target)
        notePushed(id, target)
        guard gateway.setFrame(handle, to: target) else {
            log("write win\(id) refused target=\(target)")
            return .refused
        }
        // The app may report success yet apply a different frame: a
        // minimum-size clamp (Firefox refuses to shrink past its floor
        // and lands the window half-off-screen on the right third) is
        // the shape this guards. A frame animating toward the target
        // moves along the line between the pre-write frame and the
        // target, so an applied frame off that path within tolerance is
        // not an in-flight animation: the app overrode the request. Put
        // the window back where it was before this write (the README
        // promises a refusing app's window is left alone, not
        // half-moved) and report the refusal.
        if let previous = live, let applied = gateway.frame(of: handle),
            !Self.frameOnAnimationPath(applied, from: previous, toward: target)
        {
            _ = gateway.setFrame(handle, to: previous)
            // The restore is our write too: re-point the echo trail and
            // the diff baseline at the frame the window is actually in,
            // so the restore's echo is swallowed against it instead of
            // read as a user drag.
            noteExpected(id, previous)
            notePushed(id, previous)
            log("write win\(id) clamped applied=\(applied) restored=\(previous)")
            return .refused
        }
        // Every performed write leaves exactly one outstanding check; a
        // newer write supersedes (cancels) the older, so only the latest
        // write for a window is ever judged.
        armCheck(id, consequence)
        log("write win\(id) target=\(target)")
        return .written
    }

    // MARK: Arming

    /// Notes a rect a frame write is about to push: arms the echo
    /// expectation and records the intent. Called before the gateway
    /// call, so the write's own echo can never read as a user drag.
    func noteExpected(_ id: WindowID, _ frame: CGRect) {
        expected[id] = ExpectedWrite(
            frame: frame, lastDistance: .infinity, date: now(), settled: false)
        intents[id] = frame
    }

    /// Records where a window is going without arming an expectation: no
    /// write is in flight. Untile-all primes the slot rects its undo will
    /// write, and the drag loop primes the pushes it schedules; the
    /// actual write arms the expectation via `noteExpected`.
    func noteIntent(_ id: WindowID, _ frame: CGRect) {
        intents[id] = frame
    }

    /// Last frame we wanted `id` in, if any: our intent for the window, as
    /// opposed to whatever the gateway last reported. Lets diffing and
    /// snapback prefer intent over echoes. Survives `forget`.
    func intent(for id: WindowID) -> CGRect? {
        intents[id]
    }

    // MARK: The late check

    /// Schedules the one check a performed write owns, superseding any
    /// older check for the same window.
    private func armCheck(_ id: WindowID, _ consequence: Consequence) {
        cancelCheck(id)
        checkSerial += 1
        let serial = checkSerial
        let cancel = scheduleCheck { [weak self] in
            self?.fireCheck(id, serial: serial)
        }
        checks[id] = PendingCheck(serial: serial, cancel: cancel, consequence: consequence)
    }

    /// Drops the pending check for a window, cancelling its scheduled
    /// work item. A no-op when nothing is pending.
    private func cancelCheck(_ id: WindowID) {
        checks.removeValue(forKey: id)?.cancel()
    }

    /// One late check fired: judges the write it was armed for and pays
    /// the consequence when the app stayed totally silent. A firing
    /// closure whose check was cancelled or superseded judges nothing.
    private func fireCheck(_ id: WindowID, serial: Int) {
        guard let pending = checks[id], pending.serial == serial else { return }
        checks[id] = nil
        guard convergence(for: id) == .ignored else { return }
        // The entry is spent: the app never moved the window, so the
        // echo trail has nothing left to swallow.
        expected[id] = nil
        log("check win\(id): silent ignore")
        onConsequence(id, pending.consequence)
    }

    // MARK: Tick classification

    /// What one gateway tick means for the pending expectation.
    enum TickVerdict: Equatable {
        /// No expectation: the caller processes the tick fully.
        case live
        /// A close tick past the settle window: swallowed, entry gone.
        case settleExpired
        /// The write's first close tick: swallowed, the entry is settled.
        case consumed
        /// A close tick after the write converged: swallowed. The caller
        /// still checks a title-bar grab (origin drift) inside the radius.
        case settling
        /// A settled entry's tick left the echo radius: the entry is gone
        /// and the caller processes the tick live.
        case settleEnd
        /// A tick moved away from the target faster than an animation ever
        /// would: the user took over; processed live.
        case escape
        /// The write never applied within the stale window: the entry is
        /// gone and the tick is processed live.
        case stale
        /// A tick moving toward (but not at) the target: swallowed.
        case converging
    }

    /// Classifies one gateway tick against the pending expectation and
    /// advances its echo trail (settle, distance, staleness). `.live` when
    /// no expectation exists. The caller owns what each verdict means for
    /// the drag loop; the entry's own transitions happen here.
    func classify(_ id: WindowID, frame: CGRect) -> TickVerdict {
        guard var entry = expected[id] else { return .live }

        // Echo suppression: our writes apply (often animated) as a stream
        // of notifications converging on the requested frame. Swallow
        // close ticks; a tick that moves AWAY from the target means a real
        // user drag took over, so the entry clears and the tick processes
        // live.
        if Self.framesClose(entry.frame, frame, tolerance: Self.echoTolerance) {
            if entry.settled,
                now().timeIntervalSince(entry.date) > Self.settleWindow
            {
                // Settling over, but this tick already proved close:
                // swallow it against the target rather than falling
                // into the escape check below, whose stale lastDistance
                // would misread any tail offset as a takeover. The next
                // tick processes fully live.
                expected[id] = nil
                log("echo win\(id) settle-expired")
                return .settleExpired
            }
            if !entry.settled {
                // Write converged: keep swallowing close ticks through
                // the settle window instead of going live: the
                // animation tail is still in flight, and its absolute
                // positions must never reach the splitters.
                entry.settled = true
                entry.date = now()
                entry.lastDistance = 0
                expected[id] = entry
                log("echo win\(id) consumed")
                return .consumed
            }
            log("echo win\(id) settling")
            return .settling
        }

        // A settled entry leaving the radius ends settling: the entry is
        // gone and the tick is processed live below.
        if entry.settled {
            expected[id] = nil
            log("echo win\(id) settle-end")
            return .settleEnd
        }

        let distance = Self.frameDistance(entry.frame, frame)
        if distance > entry.lastDistance + 1 {
            expected[id] = nil // user took over
            log("echo win\(id) ESCAPE dist=\(distance) last=\(entry.lastDistance)")
            return .escape
        }
        if now().timeIntervalSince(entry.date) > Self.staleWrite {
            expected[id] = nil // write never applied; stop waiting
            log("echo win\(id) stale")
            return .stale
        }
        entry.lastDistance = distance
        expected[id] = entry
        log("echo win\(id) converging dist=\(distance)")
        return .converging
    }

    // MARK: Late convergence

    /// Convergence verdict for one pending write. Nil = inconclusive,
    /// leave the window alone: the entry is gone (consumed by success,
    /// cleared by takeover, or superseded by a newer write) or frames
    /// arrived but never settled. `.ignored` = the write never took
    /// effect and nothing echoed. `.converged` = a tick landed within
    /// tolerance of the target.
    enum Convergence { case converged, ignored }

    func convergence(for id: WindowID) -> Convergence? {
        guard let entry = expected[id] else { return nil }
        if entry.settled { return .converged }
        guard entry.lastDistance == .infinity else { return nil }
        // Total echo silence alone is not a silent ignore: apps that
        // round frames to an internal grid (Terminal rounds to character
        // cells) can absorb a write whose target sits within their
        // rounding distance: the frame does not actually change, so no
        // notification is emitted. Before calling it ignored, check the
        // live frame directly: within the echo tolerance of the target
        // means the write took effect (or needed no effect). An
        // UNREADABLE live frame is also not a silent ignore: it is a
        // can't-judge. During a lid close/open the frame read fails for
        // live windows, and judging that as ignored rolled fresh
        // placements back (observed on live AX); benefit of the doubt
        // applies — the next write re-verifies.
        guard let live = liveFrameOf(id) else {
            expected[id] = nil
            log("convergence win\(id): live frame unreadable, skipping")
            return nil
        }
        if Self.framesClose(entry.frame, live, tolerance: Self.echoTolerance) {
            expected[id] = nil
            log("convergence win\(id): silent but at target (live=\(live))")
            return .converged
        }
        return .ignored
    }

    // MARK: Forgetting

    /// Forgets a window: clears the echo entry and cancels the pending
    /// convergence check, so a stale expectation never swallows a future
    /// drag and a check never rolls back a window that moved on. Intent
    /// survives: undo chapters replay writes for ids whose frames were
    /// restored out from under them. Fresh `noteExpected` calls overwrite;
    /// only recycled ids could collide, and those re-note on their first
    /// new write.
    func forget(_ id: WindowID) {
        expected[id] = nil
        cancelCheck(id)
    }

    // MARK: Geometry helpers

    private static func framesClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.maxX - b.maxX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }

    /// True when `a` and `b` differ by at most `tolerance` per edge.
    static func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        framesClose(a, b, tolerance: tolerance)
    }

    /// Sum of per-edge deltas between two frames.
    private static func frameDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.maxX - b.maxX)
            + abs(a.minY - b.minY) + abs(a.maxY - b.maxY)
    }

    // MARK: Clamp detection

    /// Whether `applied` could be a step of an animation from `previous`
    /// toward `target`. A frame animation interpolates the two endpoint
    /// frames, so each axis's (origin, size) pair moves along the straight
    /// line joining its previous and target pairs; an applied pair off
    /// that line (beyond `tolerance`) cannot be in flight. The write
    /// policy reads this right after a successful write: off-path means
    /// the app overrode the request (e.g. a minimum-width clamp), which
    /// is a refusal wearing a success, not an echo to wait for.
    static func frameOnAnimationPath(
        _ applied: CGRect, from previous: CGRect, toward target: CGRect,
        tolerance: CGFloat = WriteExpectations.echoTolerance
    ) -> Bool {
        axisOnAnimationPath(
            origin: applied.minX, size: applied.width,
            from: previous.minX, previousSize: previous.width,
            to: target.minX, targetSize: target.width, tolerance: tolerance)
            && axisOnAnimationPath(
                origin: applied.minY, size: applied.height,
                from: previous.minY, previousSize: previous.height,
                to: target.minY, targetSize: target.height, tolerance: tolerance)
    }

    /// One axis's version of `frameOnAnimationPath`: distance from the
    /// applied (origin, size) point to the segment joining the previous
    /// and target pairs is within `tolerance`. A pair that barely moved
    /// (the segment is shorter than the tolerance) demands the applied
    /// pair to be within tolerance of it, not just of the line.
    private static func axisOnAnimationPath(
        origin: CGFloat, size: CGFloat,
        from previousOrigin: CGFloat, previousSize: CGFloat,
        to targetOrigin: CGFloat, targetSize: CGFloat,
        tolerance: CGFloat
    ) -> Bool {
        let dx = targetOrigin - previousOrigin
        let dy = targetSize - previousSize
        let lengthSquared = dx * dx + dy * dy
        let stepX = origin - previousOrigin
        let stepY = size - previousSize
        if lengthSquared <= tolerance * tolerance {
            return stepX * stepX + stepY * stepY <= tolerance * tolerance
        }
        let projection = (stepX * dx + stepY * dy) / lengthSquared
        let clampedT = min(max(projection, 0), 1)
        let residualX = stepX - clampedT * dx
        let residualY = stepY - clampedT * dy
        return residualX * residualX + residualY * residualY <= tolerance * tolerance
    }
}
