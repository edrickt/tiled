import AppKit
import ApplicationServices
import CoreGraphics

// Multi-display live validation for per-monitor tiling.
//
// Run the tiled app and the throwaway host app first, then:
//   ./scripts/run-repro.sh tools/repro/multi-display-suite.swift
//
// This suite uses sixths hotkeys (the defaults are Option-Shift), tiles
// the same slot on two displays, moves a slot on one display, and drives
// a shared splitter on one display. It then verifies that the other
// display's window never moves and that the resized display's neighbor
// follows on mouse-up.
//
// The physical events a script cannot drive safely (unplug/replug,
// rearrange, primary-display change, Mission Control swipes) remain a
// short manual checklist in tools/repro/multi-display-checklist.md.

let tol: CGFloat = 3
var pass = 0
var fail = 0

let screens = NSScreen.screens
guard screens.count >= 2 else {
    print("SKIP: multi-display suite needs at least two screens; found \(screens.count).")
    exit(0)
}
let display0 = screens[0]
let display1 = screens[1]
let visible0 = display0.visibleFrame
let visible1 = display1.visibleFrame
let primaryTop = display0.frame.maxY

// MARK: AX helpers

func axPoint(_ p: CGPoint) -> AXValue? {
    var v = p
    return AXValueCreate(AXValueType(rawValue: kAXValueCGPointType)!, &v)
}
func axSize(_ s: CGSize) -> AXValue? {
    var v = s
    return AXValueCreate(AXValueType(rawValue: kAXValueCGSizeType)!, &v)
}

func frame(of el: AXUIElement) -> CGRect? {
    var pv: CFTypeRef?, sv: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
        AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
        let pv, let sv
    else { return nil }
    var p = CGPoint(), s = CGSize()
    AXValueGetValue(pv as! AXValue, AXValueType(rawValue: kAXValueCGPointType)!, &p)
    AXValueGetValue(sv as! AXValue, AXValueType(rawValue: kAXValueCGSizeType)!, &s)
    return CGRect(origin: p, size: s) // AX coords: top-left global origin
}

func setRawFrame(_ el: AXUIElement, _ f: CGRect) {
    AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, axPoint(f.origin)!)
    AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, axSize(f.size)!)
}

func title(of el: AXUIElement) -> String {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &v)
    return v as? String ?? "?"
}

let hostPID = NSWorkspace.shared.runningApplications.first { app in
    app.localizedName == "host" || app.executableURL?.lastPathComponent == "host"
}?.processIdentifier

guard let pid = hostPID else {
    print("FATAL: host app not found")
    exit(1)
}

func hostWindows() -> [(el: AXUIElement, title: String, frame: CGRect)] {
    let app = AXUIElementCreateApplication(pid)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success,
        let arr = v as? [AXUIElement]
    else { return [] }
    return arr.compactMap { el in
        guard let f = frame(of: el) else { return nil }
        return (el, title(of: el), f)
    }
}

func actualFrame(_ t: String) -> CGRect? {
    hostWindows().first(where: { $0.title == t })?.frame
}

func post(_ e: CGEvent?) {
    e?.post(tap: .cghidEventTap)
    usleep(40_000)
}

func focus(_ t: String) {
    guard let w = hostWindows().first(where: { $0.title == t }) else { return }
    AXUIElementPerformAction(w.el, kAXRaiseAction as CFString)
    usleep(100_000)
    let c = CGPoint(x: w.frame.midX, y: w.frame.midY)
    post(CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseDown,
        mouseCursorPosition: c, mouseButton: .left))
    post(CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseUp,
        mouseCursorPosition: c, mouseButton: .left))
    usleep(150_000)
}

let kVK_U: CGKeyCode = 32 // sixthTopLeft
let kVK_O: CGKeyCode = 31 // sixthTopRight
let kVK_M: CGKeyCode = 46 // sixthBottomLeft

func hotkey(_ keyCode: CGKeyCode) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down)
        e?.flags = [.maskAlternate, .maskShift]
        post(e)
    }
}

/// A mouse-up after synthetic frame mutations: the tracker commits any
/// deferred neighbor re-push on mouse-up, exactly like a native drag end.
func liftMouse() {
    let location = CGEvent(source: nil)?.location ?? .zero
    post(CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseUp,
        mouseCursorPosition: location, mouseButton: .left))
    usleep(600_000)
}

// MARK: geometry

func axRect(_ appkit: CGRect) -> CGRect {
    CGRect(
        x: appkit.minX, y: primaryTop - appkit.maxY,
        width: appkit.width, height: appkit.height)
}

func centeredFrame(width: CGFloat, height: CGFloat, in visible: CGRect) -> CGRect {
    let w = min(width, visible.width * 0.6)
    let h = min(height, visible.height * 0.6)
    return CGRect(
        x: visible.midX - w / 2, y: visible.midY - h / 2, width: w, height: h)
}

/// The expected AX rect for a sixths slot at the default splitters.
func expectedRect(_ slot: String, in visible: CGRect) -> CGRect {
    let third = visible.width / 3
    let midY = visible.minY + visible.height / 2
    let appkit: CGRect
    switch slot {
    case "6TL":
        appkit = CGRect(
            x: visible.minX, y: midY, width: third, height: visible.height / 2)
    case "6TR":
        appkit = CGRect(
            x: visible.minX + 2 * third, y: midY,
            width: third, height: visible.height / 2)
    case "6BL":
        appkit = CGRect(
            x: visible.minX, y: visible.minY,
            width: third, height: visible.height / 2)
    default:
        fatalError("bad slot \(slot)")
    }
    return axRect(appkit)
}

// MARK: verification

func close(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= tol && abs(a.maxX - b.maxX) <= tol
        && abs(a.minY - b.minY) <= tol && abs(a.maxY - b.maxY) <= tol
}

func verifyFrame(_ label: String, _ title: String, _ expected: CGRect) {
    guard let actual = actualFrame(title) else {
        fail += 1
        print("  FAIL \(label): \(title) missing")
        return
    }
    if close(actual, expected) {
        pass += 1
        print("PASS \(label)")
    } else {
        fail += 1
        print("  FAIL \(label): \(title) exp=\(expected) act=\(actual)")
    }
}

func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String) {
    if condition {
        pass += 1
        print("PASS \(label)")
    } else {
        fail += 1
        print("  FAIL \(label): \(detail())")
    }
}

func doTile(_ title: String, _ keyCode: CGKeyCode) {
    focus(title)
    hotkey(keyCode)
    usleep(900_000)
}

/// Mutates the dragged window's edge in steps, exactly like the
/// controller sees during a native drag.
func dragEdge(_ title: String, _ edge: String, _ delta: CGFloat) {
    guard let start = actualFrame(title) else { return }
    let steps = 8
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        var next = start
        switch edge {
        case "right":
            next.size.width = max(start.width + delta * t, 80)
        case "left":
            next.origin.x = start.minX + delta * t
            next.size.width = max(start.width - delta * t, 80)
        default:
            break
        }
        if let el = hostWindows().first(where: { $0.title == title })?.el {
            setRawFrame(el, next)
        }
        usleep(30_000)
    }
    usleep(600_000)
}

// MARK: setup

let initial = hostWindows().filter { $0.title.hasPrefix("HOST") }
guard initial.count >= 3 else {
    print("FATAL: multi-display suite needs HOSTA, HOSTB, and HOSTC; found \(initial.count)")
    exit(1)
}
let hostA = initial.first(where: { $0.title == "HOSTA" })!
let hostB = initial.first(where: { $0.title == "HOSTB" })!
let hostC = initial.first(where: { $0.title == "HOSTC" })!

// Display 0 gets two hosts in separate vertical positions: focus clicks
// must land on the intended window before each hotkey.
let hostWidth = min(600, visible0.width * 0.35)
let hostHeight = min(350, visible0.height * 0.3)
let hostX = visible0.minX + visible0.width * 0.05
let hostAFrame = CGRect(
    x: hostX, y: visible0.minY + visible0.height * 0.6,
    width: hostWidth, height: hostHeight)
let hostCFrame = CGRect(
    x: hostX, y: visible0.minY + visible0.height * 0.1,
    width: hostWidth, height: hostHeight)
setRawFrame(hostA.el, axRect(hostAFrame))
setRawFrame(hostB.el, axRect(centeredFrame(width: 600, height: 350, in: visible1)))
setRawFrame(hostC.el, axRect(hostCFrame))
usleep(500_000)

// MARK: M1 - the same slot can be occupied on both displays

doTile("HOSTA", kVK_U)
doTile("HOSTB", kVK_U)
verifyFrame("M1 display 0 HOSTA sixthTopLeft", "HOSTA", expectedRect("6TL", in: visible0))
verifyFrame("M1 display 1 HOSTB sixthTopLeft", "HOSTB", expectedRect("6TL", in: visible1))

// MARK: M2 - moving a window on display 1 leaves display 0 alone

doTile("HOSTB", kVK_O) // sixthTopRight: disjoint, so a move rather than eviction
verifyFrame("M2 display 1 HOSTB sixthTopRight", "HOSTB", expectedRect("6TR", in: visible1))
verifyFrame("M2 display 0 HOSTA untouched", "HOSTA", expectedRect("6TL", in: visible0))

// MARK: M3 - a neighbor shares display 0; display 1 stays independent

doTile("HOSTC", kVK_M) // sixthBottomLeft: shares the column splitter with HOSTA
verifyFrame("M3 display 0 HOSTC sixthBottomLeft", "HOSTC", expectedRect("6BL", in: visible0))
verifyFrame("M3 display 0 HOSTA still sixthTopLeft", "HOSTA", expectedRect("6TL", in: visible0))

let display1Before = actualFrame("HOSTB")!
let display0NeighborBefore = actualFrame("HOSTC")!

// Drag display 0's left column splitter left via HOSTA's right edge.
dragEdge("HOSTA", "right", -120)
liftMouse()

let hostAAfter = actualFrame("HOSTA")!
let hostCAfter = actualFrame("HOSTC")!
let display1After = actualFrame("HOSTB")!

check(
    "M3 display 0 splitter moved",
    hostAAfter.maxX < expectedRect("6TL", in: visible0).maxX - 40,
    "HOSTA right edge \(hostAAfter.maxX) did not move far enough")
check(
    "M3 display 0 neighbor followed on mouse-up",
    close(hostCAfter, CGRect(
        x: display0NeighborBefore.minX, y: display0NeighborBefore.minY,
        width: hostAAfter.width, height: display0NeighborBefore.height)),
    "HOSTC=\(hostCAfter) HOSTA width=\(hostAAfter.width) before=\(display0NeighborBefore)")
check(
    "M3 display 1 window untouched",
    close(display1After, display1Before),
    "HOSTB before=\(display1Before) after=\(display1After)")

// MARK: M4 - the other display's splitter drag leaves display 0 alone

let display0BeforeM4 = actualFrame("HOSTA")!
let display0NeighborBeforeM4 = actualFrame("HOSTC")!
dragEdge("HOSTB", "left", -80)
liftMouse()

check(
    "M4 display 1 splitter moved",
    actualFrame("HOSTB")!.minX < display1After.minX - 40,
    "HOSTB left edge barely moved")
check(
    "M4 display 0 windows untouched",
    close(actualFrame("HOSTA")!, display0BeforeM4)
        && close(actualFrame("HOSTC")!, display0NeighborBeforeM4),
    "display 0 moved during a display 1 resize")

print("\nMulti-display suite: \(pass) passed, \(fail) failed")
print("Physical checks still manual: unplug/replug, rearrange, primary-display change, and Spaces.")
print("See tools/repro/multi-display-checklist.md.")
exit(fail == 0 ? 0 : 1)
