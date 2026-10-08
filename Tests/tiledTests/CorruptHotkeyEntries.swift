import Foundation

/// Persisted-binding entries that are malformed or out of `UInt32` range —
/// the corrupt data a hand-edited plist or an older build can leave behind.
/// Every reader of a stored binding (the store, the Disable-all park, the
/// reset backup) must reject these without trapping, so one table exercises
/// all three through the shared codec.
enum CorruptHotkeyEntries {
    static let all: [[String: Any]] = [
        [:],                                              // empty
        ["modifiers": 1],                                 // keyCode missing
        ["keyCode": 1],                                   // modifiers missing
        ["modifiers": "nope", "keyCode": 1],              // wrong type
        ["modifiers": 1, "keyCode": "nope"],              // wrong type
        ["modifiers": -5, "keyCode": 6],                  // negative modifiers
        ["modifiers": Int(UInt32.max) + 1, "keyCode": 6], // modifiers overflow
        ["modifiers": 6, "keyCode": Int(UInt32.max) + 1], // keyCode overflow
    ]
}
