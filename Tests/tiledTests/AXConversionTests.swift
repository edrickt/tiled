import XCTest
@testable import tiled

/// LiveWindowGateway's AppKit ↔ AX coordinate conversion, extracted as
/// pure functions over `primaryTop` so the subtle y-flip is testable
/// without AX elements or attached displays.
final class AXConversionTests: XCTestCase {
    /// Top edge of a hypothetical primary display in AppKit coordinates.
    private let primaryTop: CGFloat = 1050

    func testRoundTripPreservesFrame() {
        let frames = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 100, y: 200, width: 300, height: 400),
            CGRect(x: 10, y: 950, width: 300, height: 100),
            CGRect(x: -50, y: 980, width: 120, height: 80),
        ]
        for frame in frames {
            let ax = LiveWindowGateway.axTopLeft(of: frame, primaryTop: primaryTop)
            let back = LiveWindowGateway.appKitFrame(
                axOrigin: ax, size: frame.size, primaryTop: primaryTop)
            XCTAssertEqual(back, frame, "\(frame) must round-trip through AX coords")
        }
    }

    func testAXOriginIsTheTopLeftCornerCountingDownFromPrimaryTop() {
        // Window whose top edge touches the primary screen's top: AX y = 0.
        let atTop = CGRect(x: 10, y: 950, width: 300, height: 100)
        XCTAssertEqual(
            LiveWindowGateway.axTopLeft(of: atTop, primaryTop: primaryTop),
            CGPoint(x: 10, y: 0))
        // Window at the bottom of the screen: AX y counts down to its top.
        let atBottom = CGRect(x: 10, y: 0, width: 300, height: 100)
        XCTAssertEqual(
            LiveWindowGateway.axTopLeft(of: atBottom, primaryTop: primaryTop),
            CGPoint(x: 10, y: 950))
    }

    func testAppKitFrameFlipsYBackFromAXOrigin() {
        let back = LiveWindowGateway.appKitFrame(
            axOrigin: CGPoint(x: 10, y: 950),
            size: CGSize(width: 300, height: 100),
            primaryTop: primaryTop)
        XCTAssertEqual(back, CGRect(x: 10, y: 0, width: 300, height: 100))
    }
}
