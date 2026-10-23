import Foundation

/// The two places a shortcut can be parked. Section parks belong to one
/// layout's Disable all / Enable all cycle; reset backups belong to Reset
/// Shortcuts, which parks a whole pre-reset snapshot. The prefixes are
/// persisted history, not an implementation detail: earlier builds wrote
/// both namespaces, so changing either would strand every existing park.
enum ParkKind: CaseIterable {
    case section
    case resetBackup

    var keyPrefix: String {
        switch self {
        case .section: "parkedHotkey."
        case .resetBackup: "resetBackupHotkey."
        }
    }
}

/// The persistence seam for park entries. The app adapter wraps
/// UserDefaults; the in-memory adapter keeps a full park lifecycle
/// hermetic when a test must not touch the host's preferences.
protocol ParkStore: AnyObject {
    func dictionary(forKey key: String) -> [String: Any]?
    func set(_ entry: [String: Int], forKey key: String)
    func removeObject(forKey key: String)
}

final class UserDefaultsParkStore: ParkStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func dictionary(forKey key: String) -> [String: Any]? {
        defaults.dictionary(forKey: key)
    }

    func set(_ entry: [String: Int], forKey key: String) {
        defaults.set(entry, forKey: key)
    }

    func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

final class InMemoryParkStore: ParkStore {
    private var entries: [String: [String: Int]] = [:]

    func dictionary(forKey key: String) -> [String: Any]? {
        entries[key]
    }

    func set(_ entry: [String: Int], forKey key: String) {
        entries[key] = entry
    }

    func removeObject(forKey key: String) {
        entries[key] = nil
    }
}

/// The Shortcuts tab's park model: both namespaces, the reset footer's one
/// answer, and the plans that make Disable all / Enable all and Reset /
/// Restore Previous Shortcuts decisions without a view. Park entries use
/// the store's single persisted-binding codec, so corrupt data falls back
/// everywhere instead of trapping in one path.
///
/// The two namespaces never share keys: resetting must not corrupt a
/// section park mid-flight, and a section park must never be offered as a
/// reset snapshot.
final class ShortcutPark {
    private let store: ParkStore

    init(store: ParkStore = UserDefaultsParkStore()) {
        self.store = store
    }

    /// A readable park for `action`, or nil. Section parks only ever hold
    /// an enabled combo Enable all can restore; a reset snapshot is exact
    /// and may legitimately hold a disabled action.
    func binding(for action: HotkeyAction, kind: ParkKind) -> HotkeyBinding? {
        guard let entry = store.dictionary(forKey: key(for: action, kind: kind)),
              let binding = HotkeyBinding(storedEntry: entry)
        else { return nil }
        if kind == .section, binding.keyCode == nil { return nil }
        return binding
    }

    func park(_ binding: HotkeyBinding, for action: HotkeyAction, kind: ParkKind) {
        store.set(binding.storedEntry, forKey: key(for: action, kind: kind))
    }

    func clear(_ action: HotkeyAction, kind: ParkKind) {
        store.removeObject(forKey: key(for: action, kind: kind))
    }

    /// True while any reset snapshot entry is readable. A snapshot may
    /// contain disabled actions, so readability — not a live combo — is
    /// what keeps Restore Previous Shortcuts available.
    func anyResetBackup() -> Bool {
        HotkeyAction.allCases.contains {
            binding(for: $0, kind: .resetBackup) != nil
        }
    }

    /// The footer's one two-state answer: Restore while a reset snapshot
    /// exists, Reset otherwise. A second reset cannot run while this says
    /// Restore, which is why a reset never overwrites its own snapshot
    /// (T11).
    var footerTitle: String {
        anyResetBackup() ? "Restore Previous Shortcuts" : "Reset Shortcuts"
    }

    /// The Enable-all decision for one layout. `current` is the tab's full
    /// binding table (every action), so a combo claimed outside the section
    /// is a clash even when the section's own store is disabled.
    func bulkRestorePlan(
        for layout: LayoutKind,
        current: [HotkeyAction: HotkeyBinding]
    ) -> BulkRestorePlan {
        BulkRestorePlan.make(
            actions: Slot.allCases.filter { $0.layout == layout }.map(HotkeyAction.slot),
            current: current,
            parks: bindings(kind: .section))
    }

    /// The Restore Previous Shortcuts decision: one snapshot restored as a
    /// state, with the fixpoint keeping a skipped entry's visibly held combo
    /// out of an accepted entry's way.
    func snapshotRestorePlan(
        current: [HotkeyAction: HotkeyBinding]
    ) -> SnapshotRestorePlan {
        SnapshotRestorePlan.make(
            backups: bindings(kind: .resetBackup), current: current)
    }

    private func bindings(kind: ParkKind) -> [HotkeyAction: HotkeyBinding] {
        var result: [HotkeyAction: HotkeyBinding] = [:]
        for action in HotkeyAction.allCases {
            if let binding = binding(for: action, kind: kind) {
                result[action] = binding
            }
        }
        return result
    }

    private func key(for action: HotkeyAction, kind: ParkKind) -> String {
        kind.keyPrefix + action.storageKey
    }
}

/// What Enable all will do to one layout section. A completed plan writes
/// nothing: the tab applies `restored` through `HotkeyStore`, then clears
/// the parks named by `clearedParks`. A clash keeps its park for a later
/// press, and a kept edit drops its stale park so it can never strike the
/// slot later.
struct BulkRestorePlan: Equatable {
    struct Restored: Equatable {
        let action: HotkeyAction
        let binding: HotkeyBinding
    }

    struct KeptEdit: Equatable {
        let action: HotkeyAction
        let binding: HotkeyBinding
    }

    struct Clash: Equatable {
        let action: HotkeyAction
        let binding: HotkeyBinding
        let owners: [HotkeyAction]
    }

    let restored: [Restored]
    let keptEdits: [KeptEdit]
    let clashes: [Clash]

    /// Parks the tab should drop: restored entries are consumed, and a
    /// stale park behind a kept edit is discarded. A clash is deliberately
    /// absent — the entry stays for the next Enable all.
    var clearedParks: [HotkeyAction] {
        restored.map(\.action) + keptEdits.map(\.action)
    }

    /// Pure decision over the tab's current bindings and the section's
    /// parks. A slot edited while disabled keeps that edit and loses its
    /// stale park; the edit never loses to the older park. A candidate
    /// another action still holds is a clash and changes nothing.
    static func make(
        actions: [HotkeyAction],
        current: [HotkeyAction: HotkeyBinding],
        parks: [HotkeyAction: HotkeyBinding]
    ) -> BulkRestorePlan {
        var restored: [Restored] = []
        var keptEdits: [KeptEdit] = []
        var clashes: [Clash] = []
        var accepted: [HotkeyAction: HotkeyBinding] = [:]

        for action in actions {
            guard let now = current[action] else { continue }
            let candidate: HotkeyBinding?
            if let parked = parks[action], parked.keyCode != nil {
                if now.keyCode != nil, now != parked {
                    keptEdits.append(KeptEdit(action: action, binding: now))
                    continue
                }
                candidate = parked
            } else if now.keyCode == nil {
                candidate = action.defaultBinding
            } else {
                candidate = nil
            }
            guard let candidate else { continue }

            let owners = owners(
                of: candidate, excluding: action, current: current, accepted: accepted)
            if owners.isEmpty {
                accepted[action] = candidate
                restored.append(Restored(action: action, binding: candidate))
            } else {
                clashes.append(Clash(action: action, binding: candidate, owners: owners))
            }
        }
        return BulkRestorePlan(restored: restored, keptEdits: keptEdits, clashes: clashes)
    }

    /// Owners in the same order `HotkeyStore.duplicates` reports them:
    /// every action whose stored (or already accepted) binding is the
    /// candidate. Disabled candidates never collide.
    private static func owners(
        of candidate: HotkeyBinding,
        excluding action: HotkeyAction,
        current: [HotkeyAction: HotkeyBinding],
        accepted: [HotkeyAction: HotkeyBinding]
    ) -> [HotkeyAction] {
        guard candidate.keyCode != nil else { return [] }
        return HotkeyAction.allCases.filter { other in
            other != action && (current[other] == candidate || accepted[other] == candidate)
        }
    }
}

/// What Restore Previous Shortcuts will do with one reset snapshot:
/// `accepted` entries are applied and cleared, `skipped` entries name the
/// action that keeps their combo, and `remaining` is the retry state left
/// in the reset namespace. The snapshot restores as one state, so a pair
/// that swapped combos is valid even though each combo currently belongs to
/// the other action.
struct SnapshotRestorePlan: Equatable {
    struct Skipped: Equatable {
        let action: HotkeyAction
        let owners: [HotkeyAction]
    }

    let accepted: [HotkeyAction: HotkeyBinding]
    let skipped: [Skipped]
    let remaining: [HotkeyAction: HotkeyBinding]

    static func make(
        backups: [HotkeyAction: HotkeyBinding],
        current: [HotkeyAction: HotkeyBinding]
    ) -> SnapshotRestorePlan {
        let snapshot = Set(backups.keys)
        var accepted: [HotkeyAction: HotkeyBinding] = [:]
        var skipped: [Skipped] = []

        // A combo owned by another action in the snapshot is not a clash:
        // the whole snapshot is about to move, so the swapped pair lands
        // together. Only an owner outside the snapshot refuses an entry.
        for action in HotkeyAction.allCases {
            guard let candidate = backups[action] else { continue }
            guard candidate.keyCode != nil else {
                accepted[action] = candidate
                continue
            }
            let owners = HotkeyAction.allCases.filter {
                $0 != action && !snapshot.contains($0) && current[$0] == candidate
            }
            if owners.isEmpty {
                accepted[action] = candidate
            } else {
                skipped.append(Skipped(action: action, owners: owners))
            }
        }

        // A refused entry keeps its current binding, so an accepted entry
        // must not take the combo that refused entry still visibly holds.
        // Demoting the accepted entry keeps the store exactly as shown
        // until a later press can restore both.
        var changed = true
        while changed {
            changed = false
            for action in HotkeyAction.allCases {
                guard let candidate = accepted[action], candidate.keyCode != nil else { continue }
                if let owner = HotkeyAction.allCases.first(where: { other in
                    other != action && accepted[other] == nil
                        && backups[other] != nil && current[other] == candidate
                }) {
                    accepted[action] = nil
                    skipped.append(Skipped(action: action, owners: [owner]))
                    changed = true
                }
            }
        }

        var remaining: [HotkeyAction: HotkeyBinding] = [:]
        for (action, binding) in backups where accepted[action] == nil {
            remaining[action] = binding
        }
        return SnapshotRestorePlan(
            accepted: accepted, skipped: skipped, remaining: remaining)
    }
}
