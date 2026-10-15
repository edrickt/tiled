import AppKit
import ApplicationServices

// Focused latency probe: tile HOSTA into the RIGHT TWO-THIRDS, then
// corner-drag its top-right corner down-left and release. Both dragged
// edges are fixed screen edges (the drag moves no splitter), so the
// mouse-up reassert is the only thing that pulls the window back — and
// the agreed spec says that is instant (one AX write, no animation).
//
// The reported failure: the window took a few seconds to snap back after
// the release.
//
// RED when the AX frame does not return to the slot within `budget`
// seconds of the posted mouse-up. Either way it prints the post-release
// frame trajectory and the log lines captured to within ~15 ms of their
// arrival, so the late phase is visible: a late decision ("dragend")
// points at the mouse-up event path; a decision on time with a late
// snap points at the write or the target app applying it.
//
// Requires: dev tiled (TILED_DEBUG=1 → build/focus-loop-tiled.log) and
// the host app running. Drives the real cursor.
// Run: scripts/run-focus-loop.sh tools/repro/screen-edge-snapback-latency.swift

let logPath = "build/focus-loop-tiled.log"
let budget: TimeInterval = 0.75
let settleTimeout: TimeInterval = 8

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
    guard let pid = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName == "host" || $0.executableURL?.lastPathComponent == "host"
    })?.processIdentifier else { return [] }
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
func postNow(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }

// Clear latched ⌥⇧ before every drag: a latched ⌥⇧ turns drags into
// something else entirely and corrupts the experiment (see evict-drag-test).
let kVK_OptionClear: CGKeyCode = 58, kVK_ShiftClear: CGKeyCode = 56
func clearModifiers() {
    for key in [kVK_OptionClear, kVK_ShiftClear] {
        let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
        up?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}

func click(at p: CGPoint) {
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left))
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left))
}

/// The sixths family is ⌥⇧ + key; R2 (the right two-thirds) is keycode 41.
func sixthHotkey(_ keyCode: CGKeyCode) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down)
        e?.flags = [.maskAlternate, .maskShift]
        post(e)
    }
}

// MARK: screen metrics

let screen = NSScreen.screens[0]
let vf = screen.visibleFrame // AppKit
let primaryTop = screen.frame.maxY
func axRect(_ appkit: CGRect) -> CGRect {
    CGRect(x: appkit.minX, y: primaryTop - appkit.maxY, width: appkit.width, height: appkit.height)
}

func closeFrame(_ a: CGRect, _ b: CGRect, _ tol: CGFloat) -> Bool {
    abs(a.minX - b.minX) <= tol && abs(a.maxX - b.maxX) <= tol
        && abs(a.minY - b.minY) <= tol && abs(a.maxY - b.maxY) <= tol
}

// MARK: log tail

func logTail(since offset: Int) -> (newOffset: Int, text: String) {
    guard let data = FileManager.default.contents(atPath: logPath),
        let text = String(data: data, encoding: .utf8) else { return (offset, "") }
    let start = text.index(text.startIndex, offsetBy: min(offset, text.count))
    return (text.count, String(text[start...]))
}

// MARK: setup

guard let hostApp = NSWorkspace.shared.runningApplications.first(where: {
    $0.localizedName == "host" || $0.executableURL?.lastPathComponent == "host"
}) else {
    print("FATAL: host app not running"); exit(1)
}
let hostPid = hostApp.processIdentifier
guard let hosta = hostWindows().first(where: { $0.title == "HOSTA" }) else {
    print("FATAL: HOSTA missing (or not readable — runner's Accessibility permission?)"); exit(1)
}

/// On-screen normal-layer windows, front to back, in AX/CG global coords.
func onScreenWindows() -> [(pid: pid_t, bounds: CGRect)] {
    guard let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    return list.compactMap { info in
        guard (info[kCGWindowLayer as String] as? Int) == 0,
            let pid = info[kCGWindowOwnerPID as String] as? pid_t,
            let d = info[kCGWindowBounds as String] as? [String: Any],
            let x = (d["X"] as? NSNumber)?.doubleValue,
            let y = (d["Y"] as? NSNumber)?.doubleValue,
            let w = (d["Width"] as? NSNumber)?.doubleValue,
            let h = (d["Height"] as? NSNumber)?.doubleValue
        else { return nil }
        return (pid, CGRect(x: x, y: y, width: w, height: h))
    }
}

// Park HOSTA — and click it — somewhere no other window covers. The
// harness opens Terminal frontmost; a click that lands on an overlapping
// window focuses THAT window, the tile hotkey then targets it (observed:
// a Terminal window tiled to the right two-thirds), and the corner drag
// bites the wrong thing. Activate the host app first — its windows then
// sit above everything, so only sibling host windows constrain the spot
// — and fall back to a fully clear spot when activation is refused.
if NSWorkspace.shared.frontmostApplication?.processIdentifier != hostPid {
    hostApp.activate(options: [.activateAllWindows])
    usleep(400_000)
}
if NSWorkspace.shared.frontmostApplication?.processIdentifier != hostPid {
    // Plain-CLI activation is refused on modern macOS
    // (NSRunningApplication.activate above); the AX frontmost attribute
    // is the other path and is usually allowed.
    let appEl = AXUIElementCreateApplication(hostPid)
    AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    usleep(400_000)
}
let hostFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == hostPid
print("host frontmost: \(hostFrontmost)")
let blockers = (hostFrontmost
    ? [CGRect]()
    : onScreenWindows().filter { $0.pid != hostPid }.map(\.bounds))
    + hostWindows().filter { $0.title != "HOSTA" }.map(\.frame)
let parkSizes = [CGSize(width: 600, height: 400), CGSize(width: 500, height: 340),
                 CGSize(width: 440, height: 300), CGSize(width: 380, height: 260)]
let area = axRect(vf)
var park: CGRect?
outer: for size in parkSizes {
    for y in stride(from: area.minY, through: area.maxY - size.height, by: 40) {
        for x in stride(from: area.minX, through: area.maxX - size.width, by: 40) {
            let cand = CGRect(x: x, y: y, width: size.width, height: size.height)
            if blockers.allSatisfy({ !$0.intersects(cand.insetBy(dx: -8, dy: -8)) }) {
                park = cand
                break outer
            }
        }
    }
}
guard let park else {
    print("FATAL: no clear parking spot for HOSTA; covering windows:")
    for w in onScreenWindows() { print("  pid \(w.pid) \(w.bounds)") }
    exit(1)
}
setFrame(hosta.el, park)
usleep(300_000)
guard let parked = frame(of: hosta.el), closeFrame(parked, park, 8) else {
    print("FATAL: HOSTA did not move to the parking spot"); exit(1)
}

// Raise + click activates the host app and focuses HOSTA (the click
// cannot land elsewhere — the spot is clear of every other window).
AXUIElementPerformAction(hosta.el, kAXRaiseAction as CFString)
usleep(150_000)
click(at: CGPoint(x: park.midX, y: park.midY))
usleep(250_000)
if NSWorkspace.shared.frontmostApplication?.processIdentifier != hostPid {
    click(at: CGPoint(x: park.midX, y: park.midY))
    usleep(250_000)
}
guard NSWorkspace.shared.frontmostApplication?.processIdentifier == hostPid else {
    print("FATAL: could not bring the host app frontmost; the tile hotkey would target another window")
    exit(1)
}

clearModifiers()
sixthHotkey(41)
usleep(1_500_000)

guard let w = hostWindows().first(where: { $0.title == "HOSTA" }) else {
    print("FATAL: HOSTA gone after tiling"); exit(1)
}
let slot = w.frame
let expected = axRect(CGRect(
    x: vf.minX + vf.width / 3, y: vf.minY,
    width: vf.width * 2 / 3, height: vf.height))
print("placed frame: \(slot)")
guard closeFrame(slot, expected, 8) else {
    print("FATAL: HOSTA did not tile to the right two-thirds (expected \(expected))")
    print("  frontmost now: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
    exit(1)
}

var reds = 0

for round in 1...3 {
    guard let win = hostWindows().first(where: { $0.title == "HOSTA" }) else {
        print("FATAL: HOSTA gone"); exit(1)
    }
    let from = win.frame
    guard closeFrame(from, slot, 8) else {
        print("\n== round \(round): HOSTA not at the slot (\(from)) — skipped ==")
        continue
    }
    // 2pt inside the corner: the window-server resize strip, not the
    // title bar and not the body.
    let grab = CGPoint(x: from.maxX - 2, y: from.minY + 2)
    let drop = CGPoint(x: from.maxX - 170, y: from.minY + 170)

    print("\n== round \(round): top-right corner \(grab) -> \(drop) ==")

    clearModifiers()
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: grab, mouseButton: .left))
    for i in 1...20 {
        let t = CGFloat(i) / 20
        let p = CGPoint(x: grab.x + (drop.x - grab.x) * t, y: grab.y + (drop.y - grab.y) * t)
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left))
        usleep(14_000)
        if i == 12, let mid = frame(of: win.el) {
            // A corner resize pulls the top edge down and leaves the left
            // edge alone; a title-bar move drags minX along.
            if mid.minX < from.minX - 10 {
                print("GRAB MISSED: window moved, not resized (mid=\(mid))"); exit(1)
            }
            if mid.minY - from.minY < 40 {
                print("GRAB MISSED: corner not resizing (mid=\(mid))"); exit(1)
            }
        }
    }
    var logMark = logTail(since: 0).newOffset
    postNow(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: drop, mouseButton: .left))
    let tUp = Date()

    // Poll the frame and timestamp log arrivals until the window is home.
    var samples: [(TimeInterval, CGRect)] = []
    var markers: [(TimeInterval, String)] = []
    var snapped: TimeInterval?
    var stable = 0
    let deadline = tUp.addingTimeInterval(settleTimeout)
    while Date() < deadline {
        usleep(15_000)
        let t = Date().timeIntervalSince(tUp)
        if let cur = frame(of: win.el) {
            if samples.last.map({ $0.1 != cur }) ?? true {
                samples.append((t, cur))
            }
            if closeFrame(cur, slot, 8) {
                stable += 1
                if stable >= 2, snapped == nil { snapped = t }
            } else {
                stable = 0
            }
        }
        let (next, text) = logTail(since: logMark)
        logMark = next
        for line in text.split(separator: "\n") {
            if line.contains("dragend") || line.contains("push win")
                || line.contains("reassert") || line.contains("applyLayout")
                || line.contains("refus") || line.contains("rollback")
            {
                markers.append((t, String(line).trimmingCharacters(in: .whitespaces)))
            }
        }
        if let s = snapped, t > s + 0.05 { break }
    }

    for (t, f) in samples {
        print(String(format: "  %.3f  %@", t, f.debugDescription))
    }
    print("  log markers (arrival time):")
    for (t, line) in markers {
        print(String(format: "    %.3f  %@", t, line))
    }
    if let s = snapped {
        let verdict = s <= budget ? "GREEN" : "RED"
        if verdict == "RED" { reds += 1 }
        print(String(format: "  snap latency: %.0f ms — %@ (budget %.0f ms)", s * 1000, verdict, budget * 1000))
    } else {
        reds += 1
        print("  RED: window never returned within \(Int(settleTimeout))s")
        print("--- log tail ---")
        print(logTail(since: max(0, logMark - 3000)).text)
    }

    usleep(400_000)
}

print("\nVERDICT: \(reds == 0 ? "green" : "RED (\(reds)/3 rounds over budget)")")
exit(reds == 0 ? 0 : 2)
