import AppKit
import ApplicationServices

// End-to-end repro for handle identity across same-app windows sharing a
// frame, on the user-visible surface: Tiled's own menu rows plus the
// windows' frames.
//
// Regression it guards: the live gateway's element-churn fallback adopts
// a fresh AX element onto an existing handle when the frames match, to
// recover identity after a display teardown (a held element stops
// comparing equal to the app's fresh reference for the same window).
// Geometry alone cannot tell that churn from a *different* window that
// happens to share the frame — Firefox's tab tear-out opens the detached
// window at (within a point of) the source window's frame — and the old
// fallback adopted such a newcomer, so tiling it silently untiled the
// original: its record moved to the newcomer, its menu row vanished, and
// the frame the canvas kept writing was the wrong window's. Adoption by
// frame now also requires the held element to be provably stale (absent
// from the app's fresh window list, or no longer answering).
//
// The host app stands in for any two same-app windows (Firefox's
// detached window, duplicated windows, cascaded windows): tile HOSTA,
// move HOSTB onto HOSTA's exact frame, then tile HOSTB. With the bug the
// menu reads "1 tiled" with a single Right Half row; correct behaviour
// keeps both rows and both frames.
//
// Usage: HOST_PID=<pid> build/focus-suite  (see scripts/run-focus-loop.sh)

let timeout: Float = 1.0
var pass = 0, fail = 0
func check(_ ok: Bool, _ label: String) {
    if ok { pass += 1; print("PASS \(label)") }
    else { fail += 1; print(">>>> FAILED: \(label)") }
}

func attr(_ el: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name, &v) == .success else { return nil }
    return v
}
func str(_ el: AXUIElement, _ name: CFString) -> String {
    (attr(el, name) as? String) ?? ""
}
func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let pv = attr(el, kAXPositionAttribute as CFString),
        let sv = attr(el, kAXSizeAttribute as CFString)
    else { return nil }
    var p = CGPoint(), s = CGSize()
    AXValueGetValue(pv as! AXValue, AXValueType(rawValue: kAXValueCGPointType)!, &p)
    AXValueGetValue(sv as! AXValue, AXValueType(rawValue: kAXValueCGSizeType)!, &s)
    return CGRect(origin: p, size: s)
}
func setFrame(_ el: AXUIElement, _ f: CGRect) {
    var p = f.origin, s = f.size
    AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
    AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
}
func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(40_000) }

// The most recently launched host wins when the env var is absent (a
// leftover instance from an interrupted run must not hijack the drive).
let hostPID: pid_t = {
    if let raw = ProcessInfo.processInfo.environment["HOST_PID"], let pid = pid_t(raw), pid > 0 {
        return pid
    }
    let hosts = NSWorkspace.shared.runningApplications.filter {
        $0.localizedName == "host" || $0.executableURL?.lastPathComponent == "host"
    }
    let newest = hosts.sorted {
        ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast)
    }.first
    guard let pid = newest?.processIdentifier else {
        print("FATAL: no host app running and HOST_PID not set")
        exit(2)
    }
    return pid
}()
print("host pid=\(hostPID)")
let app = AXUIElementCreateApplication(hostPID)
AXUIElementSetMessagingTimeout(app, timeout)

func hostWindows() -> [(el: AXUIElement, title: String, frame: CGRect)] {
    guard let raw = attr(app, kAXWindowsAttribute as CFString),
        let arr = raw as? [AXUIElement]
    else { return [] }
    return arr.compactMap { el in
        guard let f = axFrame(el) else { return nil }
        return (el, str(el, kAXTitleAttribute as CFString), f)
    }
}
func window(_ title: String) -> (el: AXUIElement, title: String, frame: CGRect)? {
    hostWindows().first { $0.title == title }
}

func key(_ code: CGKeyCode) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
        e?.flags = [.maskAlternate, .maskShift, .maskCommand]
        post(e)
    }
}
let kVK_J: CGKeyCode = 38  // Left Half
let kVK_L: CGKeyCode = 37  // Right Half

// Focus without a synthetic click: activate the app, set the window as
// main and focused, then verify. Fatal on failure, because a hotkey
// pressed on the wrong focus tiles a real user window.
func focus(_ title: String) {
    guard let w = window(title) else { print("FATAL: no \(title)"); exit(2) }
    for attempt in 0..<4 {
        NSRunningApplication(processIdentifier: hostPID)?.activate(options: [.activateAllWindows])
        usleep(200_000)
        AXUIElementPerformAction(w.el, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(w.el, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(w.el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(250_000)
        if let fw = attr(app, kAXFocusedWindowAttribute as CFString),
            CFGetTypeID(fw) == AXUIElementGetTypeID(),
            CFEqual(fw as! AXUIElement, w.el)
        { return }
        print("focus(\(title)) attempt \(attempt + 1) refused")
    }
    print("FATAL: could not focus \(title)")
    exit(2)
}

/// Tiled's menu rows: the state the user sees.
func tiledMenuLines() -> [String] {
    guard let tiled = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName == "Tiled" || $0.executableURL?.lastPathComponent == "tiled"
    }) else { return [] }
    let t = AXUIElementCreateApplication(tiled.processIdentifier)
    AXUIElementSetMessagingTimeout(t, timeout)
    guard let rawExtras = attr(t, kAXExtrasMenuBarAttribute as CFString),
        CFGetTypeID(rawExtras) == AXUIElementGetTypeID(),
        let kids = attr(rawExtras as! AXUIElement, kAXChildrenAttribute as CFString) as? [AXUIElement],
        let item = kids.first,
        let menus = attr(item, kAXChildrenAttribute as CFString) as? [AXUIElement],
        let menu = menus.first
    else { return [] }
    var lines: [String] = []
    func walk(_ el: AXUIElement, _ depth: Int) {
        guard depth < 4 else { return }
        if str(el, kAXRoleAttribute as CFString) == "AXMenuItem" {
            lines.append(str(el, kAXTitleAttribute as CFString))
        }
        if let kids = attr(el, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            for k in kids { walk(k, depth + 1) }
        }
    }
    walk(menu, 0)
    return lines
}

let screen = NSScreen.screens[0]
let vf = screen.visibleFrame
let primaryTop = screen.frame.maxY
func axRect(_ appkit: CGRect) -> CGRect {
    CGRect(x: appkit.minX, y: primaryTop - appkit.maxY, width: appkit.width, height: appkit.height)
}
let leftHalf = axRect(CGRect(x: vf.minX, y: vf.minY, width: vf.width / 2, height: vf.height))
let rightHalf = axRect(CGRect(x: vf.midX, y: vf.minY, width: vf.width / 2, height: vf.height))
func close(_ a: CGRect, _ b: CGRect, tol: CGFloat = 3) -> Bool {
    abs(a.minX - b.minX) <= tol && abs(a.maxX - b.maxX) <= tol
        && abs(a.minY - b.minY) <= tol && abs(a.maxY - b.maxY) <= tol
}

// MARK: setup: park the windows apart

for w in hostWindows() {
    switch w.title {
    case "HOSTA": setFrame(w.el, axRect(CGRect(x: 200, y: 500, width: 600, height: 350)))
    case "HOSTB": setFrame(w.el, axRect(CGRect(x: 300, y: 120, width: 600, height: 300)))
    case "HOSTC": setFrame(w.el, axRect(CGRect(x: 300, y: 300, width: 500, height: 200)))
    case "HOSTD": setFrame(w.el, axRect(CGRect(x: 1050, y: 100, width: 400, height: 250)))
    default: break
    }
}
usleep(500_000)

// MARK: 1. tile HOSTA left half

focus("HOSTA")
key(kVK_J)
usleep(1_200_000)
guard let aTiled = window("HOSTA")?.frame else { print("FATAL: HOSTA gone"); exit(2) }
print("HOSTA after Left Half: \(aTiled)")
check(close(aTiled, leftHalf), "HOSTA tiled Left Half")

// MARK: 2. collision: HOSTB onto HOSTA's exact frame, then focus it

guard let b = window("HOSTB") else { print("FATAL: HOSTB gone"); exit(2) }
setFrame(b.el, aTiled)
usleep(400_000)
print("HOSTB moved onto HOSTA's frame: \(window("HOSTB")?.frame ?? .zero)")
focus("HOSTB")
usleep(400_000)

// MARK: 3. tile HOSTB right half

key(kVK_L)
usleep(1_200_000)

// MARK: 4. asserts

let aFinal = window("HOSTA")?.frame ?? .zero
let bFinal = window("HOSTB")?.frame ?? .zero
let menu = tiledMenuLines()
print("HOSTA final: \(aFinal)")
print("HOSTB final: \(bFinal)")
print("menu final:")
for line in menu where line.contains("·") { print("   \(line)") }

check(close(aFinal, leftHalf), "HOSTA still at Left Half")
check(close(bFinal, rightHalf), "HOSTB tiled Right Half")
check(menu.contains(where: { $0.contains("Left Half") && $0.contains("host") }),
    "Tiled still lists a Left Half window")
check(menu.contains(where: { $0.contains("Right Half") && $0.contains("host") }),
    "Tiled lists a Right Half window")

print("RESULT pass=\(pass) fail=\(fail)")
exit(fail == 0 ? 0 : 1)
