import AppKit

// Host app: four plain resizable windows to tile. The suite tiles,
// drags, evicts, and closes HOSTA through HOSTD, so all four must exist:
// a missing one turns its scenarios into silent no-ops (a close of a
// window that was never there reads as a pass).
let app = NSApplication.shared
app.setActivationPolicy(.regular)

func makeWindow(_ title: String, _ frame: CGRect) -> NSWindow {
    let w = NSWindow(
        contentRect: frame,
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false)
    w.title = title
    // The repro suite drives frames directly; macOS state restoration
    // would restore some earlier run's frame on key-in, silently
    // overwriting what the suite (or the window manager) just wrote.
    w.isRestorable = false
    w.makeKeyAndOrderFront(nil)
    return w
}

// macOS window tabbing can merge two same-app windows into one tabbed
// window under the suite's feet; the suite needs four independent windows.
NSWindow.allowsAutomaticWindowTabbing = false

// AppKit coords (bottom-left origin). Screen ~1512x982.
let a = makeWindow("HOSTA", NSRect(x: 200, y: 500, width: 600, height: 350))
let b = makeWindow("HOSTB", NSRect(x: 250, y: 120, width: 600, height: 300))
let c = makeWindow("HOSTC", NSRect(x: 300, y: 300, width: 500, height: 200))
let d = makeWindow("HOSTD", NSRect(x: 1050, y: 100, width: 400, height: 250))
_ = a; _ = b; _ = c; _ = d
app.run()
