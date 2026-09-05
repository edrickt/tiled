import AppKit

extension NSApplication {
    /// Bring the app forward as the active application.
    ///
    /// `activate(ignoringOtherApps:)` is soft-deprecated on macOS 14 in
    /// favor of plain `activate()`; branch once here so every call site
    /// stays a one-liner and the LSUIElement windows (Settings, the
    /// permission explainer) still arrive frontmost on older systems.
    func activateAsFrontmost() {
        if #available(macOS 14.0, *) {
            activate()
        } else {
            activate(ignoringOtherApps: true)
        }
    }
}
