import Carbon.HIToolbox

/// Owns the one Carbon event handler a `HotkeyService` installs.
///
/// The handler's `userData` is the service's routing context. Holding it
/// unretained behind a process-wide "install once" flag left the handler
/// installed after its service died, pointing at a freed context (a later
/// hotkey press dereferences freed memory), and a replacement service
/// never installed its own. This owner keeps the context retained for as
/// long as the handler is installed and removes the handler on deinit, so
/// the handler and the context it points at cannot outlive each other.
///
/// The install/remove calls are injected so a test can exercise the
/// lifetime contract without a live Carbon event loop.
final class CarbonEventHandler<Payload: AnyObject> {
    private let userData: UnsafeMutableRawPointer
    private let handlerRef: EventHandlerRef?
    private let removeHandler: (EventHandlerRef) -> Void

    /// Installs one handler. `install` receives the retained context
    /// pointer and fills the handler ref; `remove` unregisters it at
    /// deinit. A nil ref (the install failed) removes nothing.
    init(
        payload: Payload,
        install: (UnsafeMutableRawPointer, inout EventHandlerRef?) -> Void,
        remove: @escaping (EventHandlerRef) -> Void
    ) {
        self.removeHandler = remove
        let pointer = Unmanaged.passRetained(payload).toOpaque()
        self.userData = pointer
        var ref: EventHandlerRef?
        install(pointer, &ref)
        self.handlerRef = ref
    }

    deinit {
        if let handlerRef { removeHandler(handlerRef) }
        Unmanaged<Payload>.fromOpaque(userData).release()
    }
}
