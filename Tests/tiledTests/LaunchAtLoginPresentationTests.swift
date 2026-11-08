import ServiceManagement
import XCTest

@testable import tiled

/// The Launch at Login row reads the live `SMAppService` status. A login
/// item the user must approve in Login Items is neither off nor enabled,
/// and calling register() again throws instead of approving it, so the
/// presentation keeps it checked and points at the approval step.
final class LaunchAtLoginPresentationTests: XCTestCase {
    func testStatusMappingKeepsRequiresApprovalCheckedWithItsOwnSentence() {
        XCTAssertEqual(
            LaunchAtLoginPresentation.make(status: .enabled), .enabled)
        XCTAssertEqual(
            LaunchAtLoginPresentation.make(status: .requiresApproval),
            .awaitingApproval)
        XCTAssertEqual(
            LaunchAtLoginPresentation.make(status: .notRegistered), .off)
        XCTAssertEqual(
            LaunchAtLoginPresentation.make(status: .notFound), .off)

        let awaiting = LaunchAtLoginPresentation.awaitingApproval
        XCTAssertTrue(
            awaiting.isChecked,
            "An item waiting for approval is not off; an unchecked box would invite register() again.")
        let explanation = awaiting.approvalExplanation ?? ""
        XCTAssertTrue(explanation.contains("waiting for approval"))
        XCTAssertTrue(
            explanation.contains("Login Items"),
            "The row must name where the user approves the login item.")
        XCTAssertNil(LaunchAtLoginPresentation.enabled.approvalExplanation)
        XCTAssertNil(LaunchAtLoginPresentation.off.approvalExplanation)
        XCTAssertFalse(LaunchAtLoginPresentation.off.isChecked)
    }
}
