import Foundation

/// The Shortcuts tab's one live-region message. The tab has three kinds of
/// truth to tell — a global registration failure, a refused recorder
/// conflict, and a completed action's result — and they must never race for
/// the single line. A notice owns the fixed order: failures, then a
/// conflict, then a result. A skipped restore with a live failure keeps
/// both sentences, while a reload that recomputes the same failure produces
/// an equal notice and therefore neither a label write nor an announcement.
struct ShortcutNotice: Equatable {
    enum Kind {
        case failure
        case conflict
        case result
    }

    struct Entry: Equatable {
        let kind: Kind
        let message: String
    }

    private(set) var entries: [Entry]

    /// nil when every input is empty: clearing the line is a silent act, not
    /// a notice with blank text.
    init?(failures: [String] = [], conflict: String? = nil, result: String? = nil) {
        var entries = failures
            .filter { !$0.isEmpty }
            .map { Entry(kind: .failure, message: $0) }
        if let conflict, !conflict.isEmpty {
            entries.append(Entry(kind: .conflict, message: conflict))
        }
        if let result, !result.isEmpty {
            entries.append(Entry(kind: .result, message: result))
        }
        guard !entries.isEmpty else { return nil }
        self.entries = entries
    }

    /// What the label shows and VoiceOver speaks: one sentence group per
    /// active truth, in the notice's fixed kind order.
    var text: String {
        entries.map(\.message).joined(separator: "\n")
    }
}
