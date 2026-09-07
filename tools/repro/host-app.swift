import AppKit

// Host app: two plain resizable windows to tile.
let app = NSApplication.shared
app.setActivationPolicy(.regular)

func makeWindow(_ title: String, _ frame: CGRect) -> NSWindow {
    let w = NSWindow(
        contentRect: frame,
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false)
    w.title = title
    w.makeKeyAndOrderFront(nil)
    return w
}

// AppKit coords (bottom-left origin). Screen ~1512x982.
let a = makeWindow("HOSTA", NSRect(x: 200, y: 500, width: 600, height: 350))
let b = makeWindow("HOSTB", NSRect(x: 250, y: 120, width: 600, height: 300))
let c = makeWindow("HOSTC", NSRect(x: 300, y: 300, width: 500, height: 200))
_ = a; _ = b; _ = c
app.run()
