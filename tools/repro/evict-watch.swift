import AppKit
import ApplicationServices

// Eviction-watch feedback loop for "windows randomly evict few seconds
// after tiling". Requires: tiled running with TILED_DEBUG=1 (stderr →
// /tmp/tiled-debug.log) and the host app running.
//
// Per iteration: park HOSTA, focus it, tile TL via the real hotkey, then
// watch HOSTA's frame for N seconds while scanning the tiled log for the
// distinct untile markers (verify FAILED / drag-untile / place FAILED /
// prune). RED when either the frame moves or a marker fires.
//
// Parking alternates between an arbitrary rect and the EXACT topLeft
// tile rect: an exact park makes the placement write a no-op, which no
// AX notification echoes, a known blind spot of write-time convergence
// tracking.
//
// Usage: swift tools/repro/evict-watch.swift [iterations] [watchSeconds]

let logPath = "/tmp/tiled-debug.log"
let iterations = Int(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "") ?? 12
let watchSeconds = Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "") ?? 8.0
let tol: CGFloat = 3.0

// MARK: AX helpers (same conventions as driver.swift)

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
    return CGRect(origin: p, size: s)
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

func hostPID() -> pid_t? {
    NSWorkspace.shared.runningApplications.first {
        $0.localizedName == "host" || $0.executableURL?.lastPathComponent == "host"
    }?.processIdentifier
}

func hostWindows() -> [(el: AXUIElement, title: String, frame: CGRect)] {
    guard let pid = hostPID() else { return [] }
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

func hotkey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
    down?.flags = flags
    post(down)
    let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
    up?.flags = flags
    post(up)
}

let optShift: CGEventFlags = [.maskAlternate, .maskShift]
let kVK_U: CGKeyCode = 0x20       // ⌥⇧U = top left
let kVK_Delete: CGKeyCode = 51    // ⌥⇧⌫ = evict

// MARK: screen metrics

let screen = NSScreen.screens[0]
let vf = screen.visibleFrame
let primaryTop = screen.frame.maxY
// topLeft quarter in AX coords (top-left origin, visible frame only).
let tlTile = CGRect(
    x: vf.minX, y: primaryTop - vf.maxY,
    width: vf.width / 2, height: vf.height / 2)
// A parking rect guaranteed different from any tile rect.
let arbitraryPark = CGRect(x: 260, y: 140, width: 620, height: 340)

func park(_ rect: CGRect) {
    for w in hostWindows() where w.title == "HOSTA" {
        setFrame(w.el, rect)
    }
    usleep(250_000)
}

func logTail(since offset: Int) -> (newOffset: Int, text: String) {
    guard let data = FileManager.default.contents(atPath: logPath),
        let text = String(data: data, encoding: .utf8) else { return (offset, "") }
    let start = text.index(text.startIndex, offsetBy: min(offset, text.count))
    return (text.count, String(text[start...]))
}

let untileMarkers = ["verify FAILED", "drag-untile", "place FAILED", "prune win"]

// MARK: loop

guard hostPID() != nil else { print("FATAL: host app not running"); exit(1) }

// Clear latched modifiers (see drag-test note), then untile leftover
// state from earlier runs; evict acts on the focused window only, so
// refocus HOSTA between presses.
for _ in 0..<3 {
    if let w = hostWindows().first(where: { $0.title == "HOSTA" }) {
        click(at: CGPoint(x: w.frame.midX, y: w.frame.midY))
        usleep(120_000)
    }
    hotkey(kVK_Delete, flags: optShift)
    usleep(300_000)
}

var reds = 0
for iteration in 1...iterations {
    let exactPark = iteration % 2 == 0
    park(exactPark ? tlTile : arbitraryPark)
    usleep(200_000)

    var (logOffset, _) = logTail(since: 0)

    // Focus HOSTA and tile it top-left.
    guard let a = hostWindows().first(where: { $0.title == "HOSTA" }) else {
        print("FATAL: HOSTA missing"); exit(1)
    }
    click(at: CGPoint(x: a.frame.midX, y: a.frame.midY))
    usleep(150_000)
    hotkey(kVK_U, flags: optShift)
    usleep(900_000)

    // Confirm the placement actually happened (otherwise the loop is
    // testing nothing: hotkey didn't land, permission missing, etc.).
    let (_, newLog) = logTail(since: logOffset)
    guard newLog.contains("place win") else {
        print("ITER \(iteration): FATAL no placement in log (hotkey/focus failed?); log tail:")
        print(newLog.suffix(400))
        exit(1)
    }
    logOffset = logTail(since: 0).newOffset

    guard let tiled = hostWindows().first(where: { $0.title == "HOSTA" }) else {
        print("ITER \(iteration): RED HOSTA gone"); reds += 1; continue
    }
    let tileFrame = tiled.frame
    if exactPark {
        let dx = abs(tileFrame.minX - tlTile.minX), dy = abs(tileFrame.minY - tlTile.minY)
        if dx > tol || dy > tol {
            print("ITER \(iteration): WARN exact-park offset dx=\(dx) dy=\(dy) (tile rect mismatch, fix tlTile)")
        }
    }

    // Watch: does the window leave the tile, or does the log name an untile?
    var verdict = "GREEN"
    var redReason = ""
    let pollCount = Int(watchSeconds / 0.5)
    for tick in 1...pollCount {
        usleep(500_000)
        let (_, tail) = logTail(since: logOffset)
        for marker in untileMarkers where tail.contains(marker) {
            verdict = "RED"
            redReason += " log:\(marker)"
        }
        if let now = hostWindows().first(where: { $0.title == "HOSTA" })?.frame {
            if abs(now.minX - tileFrame.minX) > tol || abs(now.minY - tileFrame.minY) > tol
                || abs(now.width - tileFrame.width) > tol || abs(now.height - tileFrame.height) > tol {
                verdict = "RED"
                redReason += " frame:\(tileFrame) -> \(now) at +\(String(format: "%.1f", Double(tick) * 0.5))s"
            }
        } else {
            verdict = "RED"
            redReason += " window vanished"
        }
        if verdict == "RED" { break }
    }
    if verdict == "RED" {
        reds += 1
        print("ITER \(iteration) (park=\(exactPark ? "exact" : "arbitrary")): RED\(redReason)")
    } else {
        print("ITER \(iteration) (park=\(exactPark ? "exact" : "arbitrary")): green")
    }

    // Reset: evict whatever state remains, then next iteration re-parks.
    hotkey(kVK_Delete, flags: optShift)
    usleep(400_000)
}

print("DONE \(iterations) iterations, \(reds) red")
exit(reds > 0 ? 2 : 0)
