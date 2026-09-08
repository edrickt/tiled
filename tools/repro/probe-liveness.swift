import AppKit
import ApplicationServices

// Liveness-probe harness for tiled's prune path. Reports the AXError the
// app's liveness probe (kAXPositionAttribute read, 1s messaging timeout)
// gets for every window of every regular app. Run before, during, and
// after a display-sleep cycle:
//   swift probe-liveness.swift            # baseline (display awake)
//   pmset displaysleepnow                 # display off, system awake
//   swift probe-liveness.swift            # while display is off
//   caffeinate -u -t 1                    # wake the display
//   swift probe-liveness.swift            # immediately after wake

let timeout: Float = 1.0

func errName(_ e: AXError) -> String {
    switch e {
    case .success: return "success"
    case .failure: return "failure"
    case .invalidUIElement: return "invalidUIElement"
    case .cannotComplete: return "cannotComplete"
    case .attributeUnsupported: return "attributeUnsupported"
    case .apiDisabled: return "apiDisabled"
    default: return "raw(\(e.rawValue))"
    }
}

let systemWide = AXUIElementCreateSystemWide()
AXUIElementSetMessagingTimeout(systemWide, timeout)

var probed = 0
var outcomes: [String: Int] = [:]

let apps = NSWorkspace.shared.runningApplications.filter {
    $0.activationPolicy == .regular
}
for app in apps {
    guard let pid = app.processIdentifier as pid_t?, pid != 0 else { continue }
    let axApp = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(axApp, timeout)
    var windowsRef: CFTypeRef?
    let windowsError = AXUIElementCopyAttributeValue(
        axApp, kAXWindowsAttribute as CFString, &windowsRef)
    guard windowsError == .success, let windows = windowsRef as? [AXUIElement] else {
        outcomes["windows:\(errName(windowsError))", default: 0] += 1
        continue
    }
    for window in windows {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            window, kAXPositionAttribute as CFString, &value)
        probed += 1
        outcomes["position:\(errName(error))", default: 0] += 1
    }
}

let stamp = CFAbsoluteTimeGetCurrent()
print("[\(stamp)] apps=\(apps.count) windowsProbed=\(probed)")
for (key, count) in outcomes.sorted(by: { $0.key < $1.key }) {
    print("  \(key): \(count)")
}
