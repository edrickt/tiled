/// One scoped read of the state the menu bar describes, built from the one
/// canvas key a refresh pass resolved. The canvas's own notice, error,
/// layout, undo chapter, and splitter backup all come from that key, and
/// warnings, rows, trust, focus, and expand state are read once here too.
///
/// Nothing re-resolves focus: a background canvas's menu can never carry
/// the focused canvas's refusal, and the menu and glyph can never describe
/// two canvases when focus moves mid-pass.
struct MenuReads {
    let space: TilingSpaceKey
    let canvas: TilingSpace
    let isTrusted: Bool
    let tileError: String?
    let hotkeyWarnings: [String]
    let rows: [TilingController.TiledWindowInfo]
    let expandState: ExpandToggleState
    /// The live combo label for every action that has one; absent means
    /// disabled. Labels are part of the snapshot so a remap is an ordinary
    /// value difference, never a force-rebuild escape.
    let labels: [HotkeyAction: String]
    /// Active layout per display for the manage list's section headers. The
    /// nil key is the passed canvas's own layout: an untagged (legacy) row
    /// describes the canvas the menu is scoped to.
    private let layoutByScreen: [ScreenID?: LayoutKind]

    init(
        space: TilingSpaceKey,
        controller: TilingController,
        failedActions: [HotkeyAction],
        binding: (HotkeyAction) -> HotkeyBinding
    ) {
        let canvas = controller.canvas(for: space)
        self.space = space
        self.canvas = canvas
        self.isTrusted = controller.isTrusted
        self.tileError = canvas.error
        self.hotkeyWarnings = failedActions.map { action in
            MenuText.hotkeyFailureWarning(
                label: binding(action).label,
                title: action.title,
                recovery: action.registrationRecovery)
        }
        let rows = controller.tiledWindowsInfo
        self.rows = rows
        self.expandState = controller.focusedExpandState
        var labels: [HotkeyAction: String] = [:]
        for action in HotkeyAction.allCases {
            if let label = binding(action).label { labels[action] = label }
        }
        self.labels = labels
        var layouts: [ScreenID?: LayoutKind] = [nil: canvas.state.layout]
        for row in rows {
            guard let screen = row.screen else { continue }
            layouts[screen] = controller.canvas(for: screen).state.layout
        }
        self.layoutByScreen = layouts
    }

    func layout(for screen: ScreenID?) -> LayoutKind {
        layoutByScreen[screen] ?? canvas.state.layout
    }

    /// Pure multi-display grouping for the manage list. The grouping key is
    /// the display's `ScreenID` (identity); the display name is used only
    /// for the header text. One section per display that has windows, in
    /// controller order. Two same-named displays stay separate because
    /// identity, not the name, groups them. Single monitor (or no screen
    /// tags) renders the flat legacy list.
    static func monitorPresentation(
        rows: [TilingController.TiledWindowInfo],
        layoutForScreen: (ScreenID?) -> LayoutKind
    ) -> (sections: [MenuModel.Snapshot.MonitorSection],
          tiledWindows: [MenuModel.Snapshot.TiledWindow],
          statusLine: String) {
        // One row per window: a display with both an identified and a
        // withheld canvas can emit the same window from both canvases, and
        // the manage list must never double-list it (nor count it twice).
        var seen: Set<WindowID> = []
        let rows = rows.filter { seen.insert($0.id).inserted }
        let grouped = Dictionary(grouping: rows, by: \.screen)
        let sections: [MenuModel.Snapshot.MonitorSection]
        let orderedRows: [MenuModel.Snapshot.TiledWindow]
        if grouped.count > 1 || (grouped.count == 1 && grouped.keys.first != nil) {
            var built: [MenuModel.Snapshot.MonitorSection] = []
            var ordered: [MenuModel.Snapshot.TiledWindow] = []
            for row in rows {
                if !built.contains(where: { $0.key == row.screen }) {
                    let count = rows.filter { $0.screen == row.screen }.count
                    let layout = layoutForScreen(row.screen)
                    let display = row.screenName ?? "Display"
                    let noun = count == 1 ? "1 tiled" : "\(count) tiled"
                    built.append(.init(
                        title: "\(display) · \(layout.title) · \(noun)",
                        key: row.screen))
                }
                ordered.append(.init(
                    id: row.id, slot: row.slot, appName: row.appName,
                    screen: row.screen))
            }
            sections = built
            orderedRows = ordered
        } else {
            sections = []
            orderedRows = rows.map {
                .init(id: $0.id, slot: $0.slot, appName: $0.appName)
            }
        }
        // Status line: one monitor reads as before; two read per
        // display ("Display 1 · Quarters · 2 tiled + Display 2 · Sixths
        // · 1 tiled") so the compass never hides a background monitor.
        let statusLine: String
        if sections.isEmpty {
            statusLine = "Layout: \(layoutForScreen(nil).title) · \(rows.count) tiled"
        } else {
            statusLine = sections.map(\.title).joined(separator: " + ")
        }
        return (sections, orderedRows, statusLine)
    }
}
