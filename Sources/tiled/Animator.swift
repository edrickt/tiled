import CoreGraphics
import Foundation

/// Steps a window's frame toward a target over a fixed duration with a
/// cubic ease-out: Tiled-driven animation.
///
/// Decorative by contract. The frame-write policy decides whether a move
/// animates, arms the echo expectation, and classifies the landing; this
/// module only shapes the intermediate frames, so a dropped step never
/// changes where a window ends up. One glide per window: a newer target
/// supersedes an in-flight glide, and motion resumes from the window's
/// current frame. The hand always wins: a pure-origin divergence from the
/// last step cancels the glide without landing it.
final class Animator {
    /// Schedules one step; returns a canceller. Injectable so tests fire
    /// steps by hand, following `DragTracker.DragEndScheduler`'s shape.
    typealias StepScheduler = (_ fire: @escaping () -> Void) -> () -> Void

    /// 180ms cubic ease-out at ~60Hz: the locked feel-pass verdict.
    static let duration: TimeInterval = 0.18
    static let stepInterval: TimeInterval = 1.0 / 60.0
    /// Pure-origin divergence this far (summed per-edge) from our last
    /// step reads as a hand on the title bar, not our own motion. Same
    /// metric and shape as DragTracker's title-bar classification.
    static let handTolerance: CGFloat = 8
    /// An observed frame this much farther from the target than the
    /// frame the last step asked for reads as lagging the schedule: the
    /// app is animating its own resize behind us, not tracking our
    /// steps. Compared against `lastWritten`, not the current expected
    /// step: every tick reads the frame before writing the step, so a
    /// perfectly tracking window is always one step behind the schedule
    /// by construction.
    private static let lagTolerance: CGFloat = 60
    /// Consecutive lagging steps that surrender a glide. Per move: no
    /// per-app memory, so the next move tries to glide again.
    private static let lagStreakLimit = 3
    /// Consecutive refused step writes that surrender a glide: an app
    /// that keeps refusing the intermediate frames gets left alone, and
    /// the landing is the one write that decides the move. Per move.
    private static let refusedStreakLimit = 3

    /// Production cadence: one step per tick on the main queue. Dispatch
    /// keeps draining while the mouse is tracking, so a glide keeps
    /// stepping under a held button where a default-mode Timer would not.
    static let scheduleStepOnMain: StepScheduler = { fire in
        let item = DispatchWorkItem(block: fire)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Animator.stepInterval, execute: item)
        return { item.cancel() }
    }

    private struct Glide {
        let id: WindowID
        let handle: WindowHandle
        let start: CGRect
        let target: CGRect
        let began: Date
        /// The frame the last step asked for: the hand-detection baseline.
        var lastWritten: CGRect
        /// Consecutive steps the observed frame lagged that ask. Reset
        /// the moment the window tracks again.
        var lagStreak = 0
        /// Consecutive step writes the gateway refused. Reset by the
        /// first accepted step.
        var refusedStreak = 0
        var cancelStep: (() -> Void)?
    }

    private let now: () -> Date
    private let scheduleStep: StepScheduler
    private let isEnabled: () -> Bool
    private let reduceMotion: () -> Bool
    private let frameOf: (WindowHandle) -> CGRect?
    private let setFrame: (WindowHandle, CGRect) -> Bool
    private let log: (String) -> Void

    /// One glide per window handle. Keyed by the handle rather than the
    /// canvas id: a window released and re-attached under a fresh id is
    /// still the same window, and its old glide must be superseded, not
    /// left stepping beside the new one.
    private var glides: [WindowHandle: Glide] = [:]

    init(
        now: @escaping () -> Date,
        scheduleStep: @escaping StepScheduler,
        isEnabled: @escaping () -> Bool,
        reduceMotion: @escaping () -> Bool,
        frameOf: @escaping (WindowHandle) -> CGRect?,
        setFrame: @escaping (WindowHandle, CGRect) -> Bool,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.now = now
        self.scheduleStep = scheduleStep
        self.isEnabled = isEnabled
        self.reduceMotion = reduceMotion
        self.frameOf = frameOf
        self.setFrame = setFrame
        self.log = log
    }

    /// Whether a move may glide right now. Read live per move: the
    /// Settings toggle and Reduce Motion both apply without a restart,
    /// and Reduce Motion always wins.
    var isAnimating: Bool { isEnabled() && !reduceMotion() }

    /// Starts (or retargets) `id`'s glide from `start` toward `target`,
    /// writing the first step synchronously so a refusal fails the move
    /// exactly like the instant path. Returns whether that first write
    /// was accepted. `land` runs the final target through the write
    /// policy when the glide ends; a cancelled glide never calls it.
    func play(
        id: WindowID, handle: WindowHandle, from start: CGRect, to target: CGRect,
        land: @escaping () -> Void
    ) -> Bool {
        // Retarget: the newest target supersedes and motion resumes from
        // where the window is (the caller's `start`), never from the
        // abandoned target. Animations never queue. The glide store is
        // keyed by handle, so supersession also reaches a glide started
        // under an id the window no longer holds.
        cancel(handle: handle)
        let glide = Glide(
            id: id, handle: handle, start: start, target: target,
            began: now(), lastWritten: start)
        let first = frame(of: glide, at: Self.stepInterval / Self.duration)
        guard setFrame(handle, first) else {
            log("glide win\(id) first step refused")
            return false
        }
        var stored = glide
        stored.lastWritten = first
        glides[handle] = stored
        schedule(handle: handle, land: land)
        log("glide win\(id) start=\(start) target=\(target)")
        return true
    }

    private func schedule(handle: WindowHandle, land: @escaping () -> Void) {
        let cancel = scheduleStep { [weak self] in
            self?.tick(handle: handle, land: land)
        }
        glides[handle]?.cancelStep = cancel
    }

    /// One scheduled step: the hand check, then either the next eased
    /// frame or the policy landing. Intermediate writes are best-effort;
    /// the clock, not the step count, decides when the glide is over, so
    /// dropped steps never change where the window ends up.
    private func tick(handle: WindowHandle, land: @escaping () -> Void) {
        guard var glide = glides[handle] else { return }
        glide.cancelStep = nil
        glides[handle] = glide

        // A user's drag wins immediately. Pure-origin divergence from the
        // last step is the title-bar shape; for windows the echo
        // classifier ignores (restored, untiled), this read-back is the
        // only detector. Cancel without a final write: the hand owns the
        // frame now.
        if let observed = frameOf(glide.handle) {
            let sizeHeld = abs(observed.width - glide.lastWritten.width) < 1
                && abs(observed.height - glide.lastWritten.height) < 1
            if sizeHeld,
                DragTracker.frameDistance(observed, glide.lastWritten) > Self.handTolerance
            {
                glides[handle] = nil
                log("glide win\(glide.id) cancelled: hand took over")
                return
            }
            // Graceful surrender: an observed frame persistently behind
            // where the last step asked reads as an app animating its own
            // resize; writing more steps would fight it. The hand check
            // above keeps precedence: a pure-origin divergence is a hand
            // (or a frozen write), cancelled without landing. Surrender
            // runs the policy landing now, so the app's own animation
            // finishes on the exact target, and leaves every other
            // window's glide running. Per move: nothing is remembered
            // about the app, so the next move tries to glide again.
            let lagging = DragTracker.frameDistance(observed, glide.target)
                > DragTracker.frameDistance(glide.lastWritten, glide.target)
                    + Self.lagTolerance
            if lagging {
                glide.lagStreak += 1
            } else {
                glide.lagStreak = 0
            }
            if glide.lagStreak >= Self.lagStreakLimit {
                surrender(handle: handle, land: land, reason: "lagging schedule")
                return
            }
            glides[handle] = glide
        }

        let progress = now().timeIntervalSince(glide.began) / Self.duration
        if progress >= 1 {
            // The glide is over: run the exact target through the write
            // policy (clamp repin and refusal classification included),
            // never a raw gateway write.
            glides[handle] = nil
            land()
            log("glide win\(glide.id) landed target=\(glide.target)")
            return
        }
        let expected = frame(of: glide, at: progress)
        if !DragTracker.close(expected, glide.lastWritten, tolerance: 0.5) {
            if setFrame(glide.handle, expected) {
                glide.lastWritten = expected
                glide.refusedStreak = 0
            } else {
                glide.refusedStreak += 1
                if glide.refusedStreak >= Self.refusedStreakLimit {
                    surrender(handle: handle, land: land, reason: "refused steps")
                    return
                }
            }
        }
        glides[handle] = glide
        schedule(handle: handle, land: land)
    }

    /// Graceful surrender: stop stepping this window and run the policy
    /// landing now. The landing is the same closure the end-of-glide
    /// path runs, so the exact target goes through the write policy
    /// (clamp repin and refusal classification included) and a refused
    /// landing reaches its rollback; the app's own animation or that
    /// refusal path finishes the move. Other glides are untouched.
    private func surrender(
        handle: WindowHandle, land: @escaping () -> Void, reason: String
    ) {
        guard let glide = glides.removeValue(forKey: handle) else { return }
        land()
        log("glide win\(glide.id) surrendered: \(reason); landed target=\(glide.target)")
    }

    /// Drops an in-flight glide without landing it: a newer target
    /// supersedes it, and the hand owns a grabbed window. Also the
    /// instant paths' supersession: a snapped move must not be
    /// overwritten by a stale glide still in flight for the window.
    func cancel(handle: WindowHandle) {
        glides.removeValue(forKey: handle)?.cancelStep?()
    }

    private func frame(of glide: Glide, at progress: Double) -> CGRect {
        let t = CGFloat(Self.easeOut(progress))
        return CGRect(
            x: Self.lerp(glide.start.minX, glide.target.minX, t),
            y: Self.lerp(glide.start.minY, glide.target.minY, t),
            width: Self.lerp(glide.start.width, glide.target.width, t),
            height: Self.lerp(glide.start.height, glide.target.height, t))
    }

    /// Cubic ease-out clamped to [0, 1]: monotone and never overshooting,
    /// so the drag tracker's escape rule (a rising distance-to-target)
    /// can never trip on our own motion.
    private static func easeOut(_ progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return 1 - pow(1 - clamped, 3)
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }
}
