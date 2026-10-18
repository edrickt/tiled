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

    func testPermissionGrantOnFirstRunShowsWelcome() {
        XCTAssertEqual(
            AppStartCompletion.make(
                afterPermissionWait: true, didDismissWelcome: false),
            .showWelcome)
    }

    func testPermissionGrantAfterDismissalRefreshesPermissionRows() {
        XCTAssertEqual(
            AppStartCompletion.make(
                afterPermissionWait: true, didDismissWelcome: true),
            .refreshPermissionRows)
    }

    func testImmediateStartRefreshesPermissionRows() {
        // No wait means no teaching moment, even on a first run: this is
        // the already-trusted launch, not the grant arrival.
        XCTAssertEqual(
            AppStartCompletion.make(
                afterPermissionWait: false, didDismissWelcome: false),
            .refreshPermissionRows)
    }
}
