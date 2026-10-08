import CoreGraphics
import Foundation

/// One owner for a frame push's expectation: armed before the gateway
/// call, its echo trail watched tick by tick, and the convergence verdict
/// rendered one verify-delay later. Owns where the window was meant to go
/// (intent), whether our own write's echo is still in flight, and whether
/// a write the app never applied should be judged ignored.
///
/// The drag loop consumes `classify` per gateway tick and keeps only drag
/// semantics (snapback, untile, `processMove`); the controller keeps the
/// write policy, the check scheduling, and the rollback consequence.
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

    /// Armed expectations by window (echo suppression).
    private var expected: [WindowID: ExpectedWrite] = [:]
    /// Last frame we wanted each window in, written or not.
    private var intents: [WindowID: CGRect] = [:]

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

    /// Clock for echo-bookkeeping timestamps. Injectable so tests can
    /// fast-forward past the stale-write window without waiting on a
    /// real 3-second timeout.
    private let now: () -> Date
    /// The window's live frame, as the app reports it; unlike intent,
    /// which says where we wanted the window, this says where it actually
    /// is. The silent-ignore check consults it before calling total echo
    /// silence an ignore: apps that round frames to an internal grid can
    /// absorb a write without emitting anything.
    private let liveFrameOf: (WindowID) -> CGRect?
    /// Cancels the pending convergence check for a window. Injected so
    /// `forget` can drop the check; scheduling itself still lives with
    /// the controller until the write path moves in here.
    private let cancelCheck: (WindowID) -> Void
    private let log: (String) -> Void

    init(
        now: @escaping () -> Date = Date.init,
        liveFrameOf: @escaping (WindowID) -> CGRect? = { _ in nil },
        cancelCheck: @escaping (WindowID) -> Void = { _ in },
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.now = now
        self.liveFrameOf = liveFrameOf
        self.cancelCheck = cancelCheck
        self.log = log
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

    /// Convergence verdict for one pending write, read by the controller's
    /// late verification. Nil = inconclusive, leave the window alone:
    /// the entry is gone (consumed by success, cleared by takeover, or
    /// superseded by a newer write) or frames arrived but never settled.
    /// `.ignored` = the write never took effect and nothing echoed.
    /// `.converged` = a tick landed within tolerance of the target.
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
}
