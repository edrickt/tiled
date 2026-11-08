import XCTest

@testable import tiled

/// Pins the launch decisions extracted from `AppDelegate`: trusted start
/// versus the permission explainer, first-run Welcome, and hidden-icon
/// recovery. Every row of the truth table is literal, so swapping any
/// branch fails here without constructing the delegate.
final class AppLaunchPlanTests: XCTestCase {
    private func assertPlan(
        _ plan: AppLaunchPlan,
        _ mode: AppLaunchPlan.Mode,
        welcome: Bool,
        settings: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(plan.mode, mode, file: file, line: line)
        XCTAssertEqual(plan.showsWelcome, welcome, file: file, line: line)
        XCTAssertEqual(plan.showsSettings, settings, file: file, line: line)
    }

    // MARK: Launch plan truth table

    func testTrustedFirstRunStartsAndShowsWelcome() {
        let plan = AppLaunchPlan.make(
            isTrusted: true, didDismissWelcome: false, hideMenuBarIcon: false)

        assertPlan(plan, .startNow, welcome: true, settings: false)
    }

    func testTrustedFirstRunHiddenStillShowsWelcomeNotSettings() {
        // Welcome wins over hidden-icon recovery on a trusted first run:
        // the guide is the teaching moment, Settings follows later.
        let plan = AppLaunchPlan.make(
            isTrusted: true, didDismissWelcome: false, hideMenuBarIcon: true)

        assertPlan(plan, .startNow, welcome: true, settings: false)
    }

    func testTrustedDismissedHiddenStartsAndShowsSettings() {
        let plan = AppLaunchPlan.make(
            isTrusted: true, didDismissWelcome: true, hideMenuBarIcon: true)

        assertPlan(plan, .startNow, welcome: false, settings: true)
    }

    func testTrustedDismissedNotHiddenStartsOnly() {
        let plan = AppLaunchPlan.make(
            isTrusted: true, didDismissWelcome: true, hideMenuBarIcon: false)

        assertPlan(plan, .startNow, welcome: false, settings: false)
    }

    func testUntrustedFirstRunWaitsWithoutWelcomeOrSettings() {
        // Untrusted first run defers the guide until the grant arrives;
        // launch itself opens only the permission explainer.
        let plan = AppLaunchPlan.make(
            isTrusted: false, didDismissWelcome: false, hideMenuBarIcon: false)

        assertPlan(plan, .waitForPermission, welcome: false, settings: false)
    }

    func testUntrustedFirstRunHiddenStillWaitsWithoutOpeningSettings() {
        let plan = AppLaunchPlan.make(
            isTrusted: false, didDismissWelcome: false, hideMenuBarIcon: true)

        assertPlan(plan, .waitForPermission, welcome: false, settings: false)
    }

    func testUntrustedDismissedHiddenWaitsAndShowsSettings() {
        let plan = AppLaunchPlan.make(
            isTrusted: false, didDismissWelcome: true, hideMenuBarIcon: true)

        assertPlan(plan, .waitForPermission, welcome: false, settings: true)
    }

    func testUntrustedDismissedNotHiddenWaitsOnly() {
        let plan = AppLaunchPlan.make(
            isTrusted: false, didDismissWelcome: true, hideMenuBarIcon: false)

        assertPlan(plan, .waitForPermission, welcome: false, settings: false)
    }

    // MARK: Mode execution

    func testPlanExecutesTheSelectedMode() {
        var started = 0
        var waited = 0

        AppLaunchPlan.make(
            isTrusted: true, didDismissWelcome: false, hideMenuBarIcon: false
        ).execute(
            startNow: { started += 1 },
            waitForPermission: { waited += 1 })
        XCTAssertEqual(started, 1, "a trusted plan starts now")
        XCTAssertEqual(waited, 0)

        AppLaunchPlan.make(
            isTrusted: false, didDismissWelcome: false, hideMenuBarIcon: false
        ).execute(
            startNow: { started += 1 },
            waitForPermission: { waited += 1 })
        XCTAssertEqual(started, 1)
        XCTAssertEqual(waited, 1, "an untrusted plan waits for the permission")
    }

    // MARK: Start completion

    private func completion(
        afterPermissionWait: Bool,
        didDismissWelcome: Bool,
        hideMenuBarIcon: Bool = false,
        settingsVisible: Bool = true
    ) -> AppStartCompletion {
        AppStartCompletion.make(
            afterPermissionWait: afterPermissionWait,
            didDismissWelcome: didDismissWelcome,
            hideMenuBarIcon: hideMenuBarIcon,
            settingsVisible: settingsVisible)
    }

    func testPermissionGrantOnFirstRunShowsWelcome() {
        XCTAssertEqual(
            completion(afterPermissionWait: true, didDismissWelcome: false),
            .showWelcome)
    }

    func testPermissionGrantAfterDismissalRefreshesSettings() {
        XCTAssertEqual(
            completion(afterPermissionWait: true, didDismissWelcome: true),
            .refreshSettings)
    }

    func testImmediateStartRefreshesSettings() {
        // No wait means no teaching moment, even on a first run: this is
        // the already-trusted launch, not the grant arrival.
        XCTAssertEqual(
            completion(afterPermissionWait: false, didDismissWelcome: false),
            .refreshSettings)
    }

    func testHiddenIconGrantWithNoVisibleSettingsShowsIt() {
        // The user closed the auto-opened window before granting. With no
        // status item either, refreshing an invisible window would leave
        // the app with no visible surface at all.
        XCTAssertEqual(
            completion(
                afterPermissionWait: true, didDismissWelcome: true,
                hideMenuBarIcon: true, settingsVisible: false),
            .showSettings)
    }

    func testHiddenIconGrantWithVisibleSettingsOnlyRefreshes() {
        // The window is already on screen; reopening it would yank the
        // user back to General and lose the tab they were reading.
        XCTAssertEqual(
            completion(
                afterPermissionWait: true, didDismissWelcome: true,
                hideMenuBarIcon: true, settingsVisible: true),
            .refreshSettings)
    }

    func testVisibleIconGrantWithNoSettingsDoesNotOpenIt() {
        // The status item is the visible surface; only a hidden icon needs
        // Settings restored on the grant.
        XCTAssertEqual(
            completion(
                afterPermissionWait: true, didDismissWelcome: true,
                hideMenuBarIcon: false, settingsVisible: false),
            .refreshSettings)
    }

    func testImmediateHiddenIconStartLeavesSettingsToTheLaunchPlan() {
        // A trusted launch shows Settings after start; start must not open
        // it twice (and would otherwise reset the tab to General).
        XCTAssertEqual(
            completion(
                afterPermissionWait: false, didDismissWelcome: true,
                hideMenuBarIcon: true, settingsVisible: false),
            .refreshSettings)
    }
}
