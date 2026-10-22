import Foundation

/// The controller-owned identity and lifetime bookkeeping for window
/// handles: the id a handle currently wears, the id allocator, the
/// death-confirmation clock, and the pending convergence checks.
///
/// One owner replaces four maps kept in step by convention: a death
/// clock or verification names a window whose record still exists, and
/// forgetting a window clears all three in one call instead of four
/// remembered call sites. Ownership itself stays derived from the
/// canvas records (`owner`); this type deliberately keeps no id -> canvas
/// map, which would be a second registry the canvas could drift from.
final class WindowRegister {
    /// The canvas holding `id`'s record, read through the canvas table.
    /// Nil means the record is gone and the id is no longer live.
    private let owner: (WindowID) -> TilingSpaceKey?
    /// Releases a live record the handle wears on another canvas, because
    /// a canvas is claiming that handle. The claiming canvas owns the
    /// window's next write; this releases the old one without a frame
    /// write.
    private let releaseForeignClaim: (WindowID, TilingSpaceKey) -> Void
    /// The controller's convergence-check scheduler, whose cancellation
    /// closure owns the runloop timer. Injected so a test can observe
    /// cancellation without waiting.
    private let schedule: DragTracker.DragEndScheduler

    private var windowIDs: [WindowHandle: WindowID] = [:]
    private var nextID: WindowID = 1
    /// Uptime at the first dead-probe sighting per window. Cleared when
    /// the probe recovers or the record goes away.
    private var deadSince: [WindowID: TimeInterval] = [:]
    /// Pending convergence checks by window: a newer placement for the
    /// same window supersedes (cancels) the older check, and forgetting a
    /// window cancels outright.
    private var pendingVerifications: [WindowID: () -> Void] = [:]

    init(
        owner: @escaping (WindowID) -> TilingSpaceKey?,
        releaseForeignClaim: @escaping (WindowID, TilingSpaceKey) -> Void,
        schedule: @escaping DragTracker.DragEndScheduler
    ) {
        self.owner = owner
        self.releaseForeignClaim = releaseForeignClaim
        self.schedule = schedule
    }

    /// The id `handle` wears while its canvas record still lives. Once
    /// the record is gone the handle is a fresh window: nil, so callers
    /// cannot act on a dead id.
    func liveID(for handle: WindowHandle) -> WindowID? {
        guard let id = windowIDs[handle], owner(id) != nil else { return nil }
        return id
    }

    /// Allocates or reuses an id for `handle` and hands it to `key`'s
    /// canvas. A live id on the same canvas is reused; a live id on
    /// another canvas is released first, so the handle never wears two
    /// records. A stale mapping is replaced with a fresh id.
    @discardableResult
    func claim(_ handle: WindowHandle, on key: TilingSpaceKey) -> WindowID {
        if let existing = liveID(for: handle), let owner = owner(existing) {
            if owner == key { return existing }
            releaseForeignClaim(existing, owner)
        }
        let id = nextID
        nextID += 1
        windowIDs[handle] = id
        return id
    }

    /// Clears everything the controller keeps about this window: the
    /// handle's id, its death clock, and its pending convergence check.
    /// The allocator is not reset: ids are never reused.
    func forget(_ id: WindowID) {
        cancelVerification(id)
        deadSince[id] = nil
        windowIDs = windowIDs.filter { $0.value != id }
    }

    // MARK: Death confirmation

    /// The uptime at the first dead-probe sighting for `id`; records the
    /// sighting when this is the first. A later sighting keeps the
    /// original clock, so the confirmation window measures from the
    /// first dead reading.
    func deathClock(_ id: WindowID, seenAt awake: TimeInterval) -> TimeInterval {
        if let first = deadSince[id] { return first }
        deadSince[id] = awake
        return awake
    }

    func clearDeath(_ id: WindowID) {
        deadSince[id] = nil
    }

    /// Whether `id` has an unconfirmed death pending.
    func hasPendingDeath(_ id: WindowID) -> Bool { deadSince[id] != nil }

    /// Drops clocks for windows no longer reading dead: a recovered probe
    /// or a vanished record leaves no pending death.
    func retainDeaths(only ids: Set<WindowID>) {
        deadSince = deadSince.filter { ids.contains($0.key) }
    }

    // MARK: Convergence checks

    /// Schedules one convergence check for `id`, cancelling any older
    /// check for the same window: only the latest write is ever judged.
    func scheduleVerification(of id: WindowID, fire: @escaping () -> Void) {
        pendingVerifications[id]?()
        pendingVerifications[id] = schedule { [weak self] in
            self?.pendingVerifications[id] = nil
            fire()
        }
    }

    func cancelVerification(_ id: WindowID) {
        pendingVerifications[id]?()
        pendingVerifications[id] = nil
    }
}
