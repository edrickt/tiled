import XCTest
@testable import tiled

/// The menu's sticky notice: the latest action receipt is carried for the
/// focused canvas even when the action touched a background one, and is
/// bounded to the focus and action generation it was presented against.
final class NoticePresentationTests: XCTestCase {
    private let focused = TilingSpaceKey(
        screen: ScreenID(rawValue: 1), space: SpaceID(rawValue: 7))
    private let background = TilingSpaceKey(
        screen: ScreenID(rawValue: 2), space: SpaceID(rawValue: 8))
    private let third = TilingSpaceKey(
        screen: ScreenID(rawValue: 3), space: SpaceID(rawValue: 9))
    private let error =
        "Display 2: Couldn't restore “Safari”: it may still be sitting in its old tile."

    private func receipt(on canvas: TilingSpaceKey) -> ActionReceipt {
        ActionReceipt(
            canvas: canvas, performed: false, notice: error, announcement: error)
    }

    func testBackgroundReceiptOverlaysTheFocusedCanvasNotice() {
        var notices = NoticePresentation()
        notices.stateDidChange()
        notices.present(receipt(on: background), focusedSpace: focused)

        XCTAssertEqual(
            notices.overlay(
                canvasNotice: "Focused notice", canvasError: nil,
                focusedSpace: focused),
            error,
            "a background action's receipt is the latest user-visible outcome")
    }

    func testALaterGenerationOnTheFocusedCanvasSupersedesTheReceipt() {
        var notices = NoticePresentation()
        notices.stateDidChange()
        notices.present(receipt(on: background), focusedSpace: focused)
        notices.stateDidChange()

        XCTAssertEqual(
            notices.overlay(
                canvasNotice: "Fresh outcome", canvasError: nil,
                focusedSpace: focused),
            "Fresh outcome")
        XCTAssertEqual(
            notices.overlay(
                canvasNotice: "Focused notice", canvasError: nil,
                focusedSpace: focused),
            "Focused notice",
            "a superseded receipt never resurfaces, even when the new notice is nil")
    }

    func testALaterGenerationOnTheBackgroundCanvasSupersedesTheReceipt() {
        var notices = NoticePresentation()
        notices.stateDidChange()
        notices.present(receipt(on: background), focusedSpace: focused)
        notices.stateDidChange()

        XCTAssertEqual(
            notices.overlay(
                canvasNotice: "Focused notice", canvasError: "New error",
                focusedSpace: focused),
            "Focused notice",
            "the new generation owns the overlay, not the stale background receipt")
    }

    func testMovingFocusDoesNotCarryTheReceiptToAThirdCanvas() {
        var notices = NoticePresentation()
        notices.stateDidChange()
        notices.present(receipt(on: background), focusedSpace: focused)

        XCTAssertEqual(
            notices.overlay(
                canvasNotice: "Third notice", canvasError: nil,
                focusedSpace: third),
            "Third notice")
    }

    func testSameCanvasReceiptDoesNotDuplicateTheCanvasNotice() {
        var notices = NoticePresentation()
        notices.stateDidChange()
        notices.present(receipt(on: focused), focusedSpace: focused)

        XCTAssertEqual(
            notices.overlay(
                canvasNotice: "Focused notice", canvasError: nil,
                focusedSpace: focused),
            "Focused notice",
            "the receipt on this canvas is already carried by canvasNotice")
    }

    func testNilReceiptLeavesTheCanvasNoticeAlone() {
        let notices = NoticePresentation()

        XCTAssertEqual(
            notices.overlay(
                canvasNotice: "Focused notice", canvasError: nil,
                focusedSpace: focused),
            "Focused notice")
    }

    func testClearDropsTheReceiptSoARevisitCannotResurrectIt() {
        var notices = NoticePresentation()
        notices.stateDidChange()
        notices.present(receipt(on: background), focusedSpace: focused)
        notices.clear()

        XCTAssertEqual(
            notices.overlay(
                canvasNotice: "Focused notice", canvasError: nil,
                focusedSpace: focused),
            "Focused notice",
            "returning to the same canvas must not resurrect the cleared receipt")
    }
}
