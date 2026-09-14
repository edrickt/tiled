import AppKit
import ApplicationServices

// Does the target app post kAXUIElementDestroyedNotification when one of
// its windows closes, and how fast? Tiled learns about a closed window
// only from its 5s prune timer plus the 3s death confirmation, which is
// the "takes like 10 seconds" complaint. An AXObserver destroyed
// notification would let the slot release as soon as the OS says the
// element is gone.
//
// Usage: swift tools/repro/destroy-notification-probe.swift <pid> [close|kill]
//   close (default): press the first window's AX close button, then wait
//   kill: SIGKILL the whole process, then wait
//
// Prints the latency from the close to the notification, and whether the
// destroyed element's position probe fails (Tiled's own liveness input).

let timeout: Float = 1.0
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), timeout)

func attr(_ el: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name, &v) == .success else { return nil }
    return v
}

func title(of el: AXUIElement) -> String {
    attr(el, kAXTitleAttribute as CFString) as? String ?? "?"
}

guard let pid = ProcessInfo.processInfo.environment["PID"].flatMap({ pid_t($0) })
    ?? (CommandLine.arguments.count > 1 ? pid_t(CommandLine.arguments[1]) : nil)
else {
    print("usage: swift destroy-notification-probe.swift <pid> <close|kill>")
    exit(1)
}
// The mode is required, not defaulted: "close" destroys a real window of
// whatever pid was named, and a measurement probe must never do that
// because an operator forgot the second argument.
guard CommandLine.arguments.count > 2,
    let mode = ["close", "kill"].first(where: { $0 == CommandLine.arguments[2] })
else {
    print("usage: swift destroy-notification-probe.swift <pid> <close|kill>")
    print("  close: press the first window's AX close button")
    print("  kill:  SIGKILL the process")
    exit(1)
}

let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, timeout)
let targetName = (attr(app, kAXTitleAttribute as CFString) as? String) ?? "pid \(pid)"
print("target: \(targetName) (pid \(pid)), mode \(mode)")
let windows = (attr(app, kAXWindowsAttribute as CFString) as? [AXUIElement]) ?? []
guard let victim = windows.first else {
    print("FATAL: pid \(pid) has no AX windows")
    exit(1)
}
let victimTitle = title(of: victim)
print("target pid=\(pid) window '\(victimTitle)' (of \(windows.count))")

// What each notification we care about does, with arrival times.
final class Sink {
    var destroyedAt: Date?
    var movedAt: Date?
    var resizedAt: Date?
    var closePressedAt: Date?
    var observedNames: [String] = []
}
let sink = Sink()

let callback: AXObserverCallback = { _, _, notification, refcon in
    let name = notification as String
    guard let refcon else { return }
    let sink = Unmanaged<Sink>.fromOpaque(refcon).takeUnretainedValue()
    sink.observedNames.append(name)
    let now = Date()
    if name == kAXUIElementDestroyedNotification as String { sink.destroyedAt = now }
    if name == kAXWindowMovedNotification as String { sink.movedAt = now }
    if name == kAXWindowResizedNotification as String { sink.resizedAt = now }
    print("  [\(String(format: "%.3f", now.timeIntervalSince(sink.closePressedAt ?? now)))s] \(name)")
}

var observer: AXObserver?
let created = AXObserverCreate(pid, callback, &observer)
guard created == .success, let observer else {
    print("FATAL: AXObserverCreate failed (\(created.rawValue)); is AX permission granted?")
    exit(1)
}
for name in [
    kAXUIElementDestroyedNotification as CFString,
    kAXWindowMovedNotification as CFString,
    kAXWindowResizedNotification as CFString,
] {
    let status = AXObserverAddNotification(
        observer, victim, name, Unmanaged.passUnretained(sink).toOpaque())
    print("registered \(name) → AXError \(status.rawValue)")
}
CFRunLoopAddSource(
    CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), CFRunLoopMode.commonModes)

// Close (or kill) the target.
let start = Date()
sink.closePressedAt = start
if mode == "kill" {
    print("SIGKILL \(pid)")
    kill(pid, SIGKILL)
} else if let close = attr(victim, kAXCloseButtonAttribute as CFString) {
    print("pressing close button")
    let err = AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString)
    print("close AXError \(err.rawValue)")
} else {
    print("FATAL: no close button")
    exit(1)
}

// Pump the runloop so AXObserver callbacks can arrive.
let deadline = Date().addingTimeInterval(6)
while Date() < deadline && sink.destroyedAt == nil {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}

print()
if let destroyedAt = sink.destroyedAt {
    print(String(
        format: "DESTROYED notification arrived after %.3fs",
        destroyedAt.timeIntervalSince(sink.closePressedAt ?? destroyedAt)))
} else {
    print("NO destroyed notification within 6s (observed: \(sink.observedNames))")
}

// Tiled's own probe on the held element, now.
var value: CFTypeRef?
let probeError = AXUIElementCopyAttributeValue(victim, kAXPositionAttribute as CFString, &value)
print("held-element position probe now: AXError \(probeError.rawValue)")
let live = (attr(app, kAXWindowsAttribute as CFString) as? [AXUIElement]) ?? []
print("app window list still holds: \(live.count) window(s)")
