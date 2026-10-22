import Foundation

/// One refresh pass's answer to "which window has focus", memoized for a
/// moment because a menu build asks several times. The focus observer and
/// `release` clear the cache; the lifetime only bounds a pass that races a
/// notification. Clearing on release matters: a memoized handle outliving
/// its window would answer a focused-window query with a handle whose
/// element is already gone.
struct FocusMemo {
    private var cached: (handle: WindowHandle?, stamp: Date)?
    let lifetime: TimeInterval

    init(lifetime: TimeInterval = 0.05) {
        self.lifetime = lifetime
    }

    mutating func resolve(now: Date, read: () -> WindowHandle?) -> WindowHandle? {
        if let cached, now.timeIntervalSince(cached.stamp) < lifetime {
            return cached.handle
        }
        let handle = read()
        cached = (handle, now)
        return handle
    }

    /// Drops the answer only when it names the released handle. Releasing
    /// some other window must not force a system-wide AX read.
    mutating func invalidate(_ handle: WindowHandle) {
        if cached?.handle == handle {
            cached = nil
        }
    }

    mutating func clear() {
        cached = nil
    }
}
