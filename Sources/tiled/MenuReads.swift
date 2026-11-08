/// One scoped read of the state the menu bar describes, built from the one
/// canvas key a refresh pass resolved. The canvas's own notice, error,
/// layout, undo chapter, and splitter backup all come from that key, and
/// warnings, rows, trust, focus, and expand state are read once here too.
/// The tiled window list and the background refusal rows are the
/// deliberate aggregate exception: the menu describes every visible canvas
/// there, so a background canvas's refusal (a birth or reassert has no
/// receipt) cannot hide behind focus.
///
/// Nothing re-resolves focus: a background canvas's menu can never carry
/// the focused canvas's refusal, and the menu and glyph can never describe
/// two canvases when focus moves mid-pass.
struct MenuReads {
    let space: TilingSpaceKey
    let canvas: TilingSpace
    let isTrusted: Bool
    let tileError: String?
    /// Other visible canvases' refusals, display-qualified. The scoped
    /// canvas's own refusal is `tileError`, and a sentence that repeats it
    /// (in the rare single-display case where no display name can
    /// distinguish them) is dropped here.
    let backgroundTileErrors: [String]
    let hotkeyWarnings: [String]
    /// Carbon's event tap could not be installed: no global shortcut can
    /// fire, so the backend sentence replaces the per-combo warnings
    /// instead of blaming a binding that was never the problem.
    let hotkeyBackendError: String?
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
        eventTapUnavailable: Bool = false,
        binding: (HotkeyAction) -> HotkeyBinding
    ) {
        let canvas = controller.canvas(for: space)
        self.space = space
        self.canvas = canvas
        self.isTrusted = controller.isTrusted
        self.tileError = canvas.error
        var backgroundErrors: [String] = []
        for entry in controller.visibleCanvasErrors() where entry.space != space {
            let error = MenuText.displayQualified(
                entry.error, displayName: controller.displayName(for: entry.space))
            guard error != canvas.error, !backgroundErrors.contains(error) else {
                continue
            }
            backgroundErrors.append(error)
        }
        self.backgroundTileErrors = backgroundErrors
        self.hotkeyBackendError =
            eventTapUnavailable ? MenuText.eventTapUnavailableWarning() : nil
        // A dead event tap marks every enabled action failed so the tab
        // and the guide stop promising dead combos, but the menu must not
        // repeat that as one combo sentence per action: the backend
        // sentence above is the whole truth.
        self.hotkeyWarnings = eventTapUnavailable
            ? []
            : failedActions.map { action in
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
    /// identity, not the name, groups them. A display whose windows span
    /// both an identified and a withheld canvas runs two layouts at once,
    /// so its header omits the layout rather than naming one canvas's for
    /// the other's rows. Single display (or no screen tags) renders the
    /// flat legacy list.
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
                    // One display can carry an identified canvas and a
                    // withheld fallback at once, and they can run different
                    // layouts. No single layout is then true for every row,
                    // so the header omits it rather than naming one
                    // canvas's layout for the other's windows.
                    let displayRows = rows.filter { $0.screen == row.screen }
                    let count = displayRows.count
                    let layouts = Set(displayRows.map(\.slot.layout))
                    let display = row.screenName ?? "Display"
                    let noun = count == 1 ? "1 tiled" : "\(count) tiled"
                    let title =
                        layouts.count > 1
                        ? "\(display) · \(noun)"
                        : "\(display) · \(layoutForScreen(row.screen).title) · \(noun)"
                    built.append(.init(title: title, key: row.screen))
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
        // Status line: one display reads as before; two read per
        // display ("Display 1 · Quarters · 2 tiled + Display 2 · Sixths
        // · 1 tiled") so the compass never hides a background display.
        let statusLine: String
        if sections.isEmpty {
            statusLine = "Layout: \(layoutForScreen(nil).title) · \(rows.count) tiled"
        } else {
            statusLine = sections.map(\.title).joined(separator: " + ")
        }
        return (sections, orderedRows, statusLine)
    }
}
