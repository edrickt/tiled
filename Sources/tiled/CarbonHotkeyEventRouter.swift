import Carbon.HIToolbox
import Foundation

/// The process-wide Carbon event tap and the one action handler it calls.
///
/// Carbon's application event target and the handler installed on it are
/// process state, not service state: installing a callback per
/// `HotkeyService` would leave Carbon aimed at a callback whose service may
/// be gone. This router owns that one installation, parses the hotkey id,
/// resolves it through the service's one route table, and hops to the main
/// queue before delivering the action.
///
/// A service claims the handler for its lifetime; teardown clears only its
/// own claim, so a replacement service's handler survives the old service's
/// deinit.
final class CarbonHotkeyEventRouter {
    /// The production router. The event handler is installed once for the
    /// process; a second production router would leave the first one's
    /// callback in place, so callers share this one.
    static let shared = CarbonHotkeyEventRouter()

    /// Fired on the main queue for every recognized hotkey id.
    private(set) var handler: ((HotkeyAction) -> Void)?

    /// The identity of the service that installed the current handler. Paired
    /// with the handler so a dying service cannot clear its replacement's
    /// route. The identity, not a weak reference, is stored: Swift clears
    /// weak references to an object before its `deinit` body runs, so a weak
    /// owner would already read nil when teardown tries to clear it.
    private var ownerID: ObjectIdentifier?

    /// The OSStatus of the process's one event-handler installation.
    /// `noErr` means Carbon delivers hotkey events to this router; any
    /// other answer means every registration is dead however its own
    /// registration call answered.
    private(set) var eventTapStatus: OSStatus

    /// Whether Carbon's application event target delivers hotkey events.
    /// A service reads this before judging its registrations: a dead tap
    /// must surface as a backend failure, never as a lost combo.
    var isEventTapAvailable: Bool { eventTapStatus == noErr }

    /// The installation attempt, stored so a transient failure can be
    /// retried without a second `InstallEventHandler` callback ever being
    /// armed for the same event.
    private let installer: () -> OSStatus

    /// Installs Carbon's event handler once. Tests inject an installer
    /// that answers an error or `noErr` and drive `dispatch` directly, so
    /// the suites never touch the live application event target.
    init(
        installer: @escaping () -> OSStatus =
            CarbonHotkeyEventRouter.installEventHandlerOnce
    ) {
        self.installer = installer
        eventTapStatus = installer()
    }

    /// Retries a failed install: a transient failure leaves the process
    /// latch unset, so a later reload can recover without the duplicate
    /// callback a second successful install would add.
    @discardableResult
    func retryEventTapInstallIfNeeded() -> OSStatus {
        guard !isEventTapAvailable else { return eventTapStatus }
        eventTapStatus = installer()
        return eventTapStatus
    }

    /// Claims the action handler for `owner` (a `HotkeyService`). The owner
    /// identity is what `clearHandler(ifOwner:)` checks on teardown.
    func setHandler(
        _ handler: @escaping (HotkeyAction) -> Void,
        owner: AnyObject
    ) {
        ownerID = ObjectIdentifier(owner)
        self.handler = handler
    }

    /// Clears the handler only when `owner` still holds it: a replacement
    /// service's route must survive the old service's teardown.
    func clearHandler(ifOwner owner: AnyObject) {
        guard ownerID == ObjectIdentifier(owner) else { return }
        handler = nil
        ownerID = nil
    }

    /// Resolves a Carbon hotkey id through `HotkeyService.actionByID` and
    /// delivers the action on the main queue. An unknown id falls through,
    /// so another app's hotkey is never swallowed.
    func dispatch(
        hotKeyID: UInt32,
        deliver: @escaping (HotkeyAction) -> Void
    ) -> OSStatus {
        guard let action = HotkeyService.route(forHotKeyID: hotKeyID) else {
            return OSStatus(eventNotHandledErr)
        }
        DispatchQueue.main.async { deliver(action) }
        return noErr
    }

    /// Parses one Carbon event into its hotkey id and routes it. Split from
    /// `dispatch` so resolve-and-hop is testable without a synthesized event.
    func handleEvent(_ event: EventRef?) -> OSStatus {
        guard let event else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID)
        guard status == noErr else { return status }
        return dispatch(hotKeyID: hotKeyID.id) { [weak self] action in
            self?.handler?(action)
        }
    }

    private static var eventHandlerInstalled = false
    private static let eventType = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed))

    /// One `InstallEventHandler` per process: a second install would add a
    /// second callback for the same event, firing every hotkey twice. The
    /// latch arms only on `noErr`, so a failed install is retryable and
    /// never claims a tap it does not have.
    private static func installEventHandlerOnce() -> OSStatus {
        guard !eventHandlerInstalled else { return noErr }
        var eventType = Self.eventType
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonCallback,
            1,
            &eventType,
            nil,
            nil)
        if status == noErr { eventHandlerInstalled = true }
        return status
    }

    /// The callback has no per-service context: it always parses through the
    /// shared router, whose handler is the one a live service claimed.
    private static let carbonCallback: EventHandlerUPP = { _, event, _ in
        CarbonHotkeyEventRouter.shared.handleEvent(event)
    }
}
