import AppKit
import ApplicationServices

// Repro driver for tiled. Run with the tiled app + host app already running.
// Usage: swift driver.swift

let hostPID = NSWorkspace.shared.runningApplications.first { app in
    app.localizedName == "host" || app.executableURL?.lastPathComponent == "host"
}?.processIdentifier

guard let pid = hostPID else {
    print("FATAL: host app not found")
    exit(1)
}

func axPoint(_ p: CGPoint) -> AXValue? { var v = p; return AXValueCreate(AXValueType(rawValue: kAXValueCGPointType)!, &v) }
func axSize(_ s: CGSize) -> AXValue? { var v = s; return AXValueCreate(AXValueType(rawValue: kAXValueCGSizeType)!, &v) }

func frame(of el: AXUIElement) -> CGRect? {
    var pv: CFTypeRef?, sv: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
        AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
        let pv, let sv else { return nil }
    var p = CGPoint(), s = CGSize()
    AXValueGetValue(pv as! AXValue, AXValueType(rawValue: kAXValueCGPointType)!, &p)
    AXValueGetValue(sv as! AXValue, AXValueType(rawValue: kAXValueCGSizeType)!, &s)
    return CGRect(origin: p, size: s) // AX coords = top-left origin, points
}

func setFrame(_ el: AXUIElement, _ f: CGRect) {
    AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, axPoint(f.origin)!)
    AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, axSize(f.size)!)
}

func title(of el: AXUIElement) -> String {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &v)
    return v as? String ?? "?"
}

func hostWindows() -> [(el: AXUIElement, title: String, frame: CGRect)] {
    let app = AXUIElementCreateApplication(pid)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success,
        let arr = v as? [AXUIElement] else { return [] }
    return arr.compactMap { el in
        guard let f = frame(of: el) else { return nil }
        return (el, title(of: el), f)
    }
}

func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(40_000) }
func click(at p: CGPoint) {
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left))
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left))
}
func drag(from: CGPoint, to: CGPoint) {
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left))
    let steps = 30
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left))
        usleep(16_000)
    }
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left))
}
func hotkey(_ keyCode: CGKeyCode) {
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
    down?.flags = [.maskAlternate, .maskShift]
    post(down)
    let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
    up?.flags = [.maskAlternate, .maskShift]
    post(up)
}

let kVK_U: CGKeyCode = 0x20
let kVK_M: CGKeyCode = 0x2E

func dump(_ label: String, _ ws: [(el: AXUIElement, title: String, frame: CGRect)]) {
    print("--- \(label)")
    for w in ws where w.title.hasPrefix("HOST") {
        print("\(w.title): axFrame=\(w.frame)")
    }
}

// 1. Park the two windows apart
var windows = hostWindows()
for w in windows {
    switch w.title {
    case "HOSTA": setFrame(w.el, CGRect(x: 300, y: 150, width: 600, height: 350))
    case "HOSTB": setFrame(w.el, CGRect(x: 350, y: 600, width: 600, height: 300))
    default: break
    }
}
usleep(300_000)
windows = hostWindows()
dump("parked", windows)

// 2. Tile HOSTA -> TL, HOSTB -> BL
if let a = windows.first(where: { $0.title == "HOSTA" }) {
    click(at: CGPoint(x: a.frame.midX, y: a.frame.midY)); usleep(150_000)
    hotkey(kVK_U); usleep(700_000)
}
if let b = windows.first(where: { $0.title == "HOSTB" }) {
    click(at: CGPoint(x: b.frame.midX, y: b.frame.midY)); usleep(150_000)
    hotkey(kVK_M); usleep(700_000)
}
windows = hostWindows()
dump("tiled TL+BL", windows)

// 3. Drag HOSTB's top edge (shared horizontal divider) upward by 120px
guard let b = windows.first(where: { $0.title == "HOSTB" }) else {
    print("FATAL: HOSTB missing"); exit(1)
}
let edgeY = b.frame.minY + 1 // AX coords: minY is the TOP edge
drag(from: CGPoint(x: b.frame.midX, y: edgeY), to: CGPoint(x: b.frame.midX, y: edgeY - 120))
usleep(1_200_000)

// 4. Result
windows = hostWindows()
dump("after dragging shared horizontal edge up 120px", windows)

// 5. Expectation
do {
    let newBTop = b.frame.minY - 120
    print("EXPECT: HOSTA.maxY ≈ \(newBTop) (moved up 120), HOSTB.minY ≈ \(newBTop)")
}
