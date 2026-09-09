import AppKit
import ApplicationServices

// App-level death-confirmation probe for tiled. For every regular app:
// reads the app element's kAXWindowsAttribute (the authoritative "which
// windows exist" signal), then window-level position probes. Run in a
// tight loop around a lid cycle:
//   while :; do swift probe-applevel.swift >> /tmp/applevel.log; sleep 0.3; done
//
// Question this answers: during the lid-closed state where window
// element reads return invalidUIElement, does the app element still
// answer, and does its windows list still contain the live windows?

let timeout: Float = 1.0

func errName(_ e: AXError) -> String {
    switch e {
    case .success: return "success"
    case .failure: return "failure"
    case .invalidUIElement: return "invalidUIElement"
    case .cannotComplete: return "cannotComplete"
    case .attributeUnsupported: return "attributeUnsupported"
    case .apiDisabled: return "apiDisabled"
    case .noValue: return "noValue"
    default: return "raw(\(e.rawValue))"
    }
}

let stamp = CFAbsoluteTimeGetCurrent()
var lines: [String] = []
let apps = NSWorkspace.shared.runningApplications.filter {
    $0.activationPolicy == .regular
}
for app in apps {
    guard let pid = app.processIdentifier as pid_t?, pid != 0 else { continue }
    let name = app.localizedName ?? "?"
    let axApp = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(axApp, timeout)
    var windowsRef: CFTypeRef?
    let listError = AXUIElementCopyAttributeValue(
        axApp, kAXWindowsAttribute as CFString, &windowsRef)
    let windows = (listError == .success) ? (windowsRef as? [AXUIElement] ?? []) : []
    lines.append("[\(stamp)] \(name)(pid \(pid)) windowsList: \(errName(listError)) count=\(windows.count)")
    // Window-level probe on each listed window (the app's liveness path).
    for (index, window) in windows.prefix(4).enumerated() {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            window, kAXPositionAttribute as CFString, &value)
        lines.append("    win#\(index) position: \(errName(error))")
    }
}
print(lines.joined(separator: "\n"))
