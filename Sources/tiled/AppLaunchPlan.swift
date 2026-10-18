/// One launch decision for `applicationDidFinishLaunching`: whether tiling
/// starts now or waits behind the permission explainer, and which Settings
/// window (if any) launch opens. Pure and total, so the trusted/untrusted,
/// first-run, and hidden-icon combinations are pinned without a GUI.
struct AppLaunchPlan: Equatable {
    enum Mode: Equatable {
        case startNow
        case waitForPermission
    }

    let mode: Mode
    let showsWelcome: Bool
    let showsSettings: Bool

    /// Runs the selected launch mode. The delegate supplies the two
    /// effects; the plan owns which one runs.
    func execute(startNow: () -> Void, waitForPermission: () -> Void) {
        switch mode {
        case .startNow: startNow()
        case .waitForPermission: waitForPermission()
        }
    }

    /// Trusted launches start immediately; untrusted launches wait for the
    /// grant, because every controller action needs Accessibility.
    ///
    /// Welcome belongs to a trusted first run. An untrusted first run is
    /// shown it by `start(afterPermissionWait:)` when the grant arrives,
    /// so launch opens only the permission explainer. After the guide has
    /// been dismissed, a launch with a hidden menu bar icon opens Settings
    /// as the only way back in. Welcome wins when first run and hidden-icon
    /// recovery coincide.
    static func make(
        isTrusted: Bool, didDismissWelcome: Bool, hideMenuBarIcon: Bool
    ) -> AppLaunchPlan {
        let firstRun = !didDismissWelcome
        return AppLaunchPlan(
            mode: isTrusted ? .startNow : .waitForPermission,
            showsWelcome: isTrusted && firstRun,
            showsSettings: !firstRun && hideMenuBarIcon)
    }
}

/// What `start(afterPermissionWait:)` does once tiling is live. A grant
/// that arrives on a first run is the teaching moment, so it opens
/// Welcome; every other start only refreshes an already-open Settings
/// window's permission rows.
enum AppStartCompletion: Equatable {
    case showWelcome
    case refreshPermissionRows

    static func make(afterPermissionWait: Bool, didDismissWelcome: Bool) -> Self {
        if afterPermissionWait, !didDismissWelcome {
            return .showWelcome
        }
        return .refreshPermissionRows
    }
}
