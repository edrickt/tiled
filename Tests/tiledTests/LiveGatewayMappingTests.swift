import CoreGraphics
import XCTest

@testable import tiled

/// The live gateway's Space-table parsing and display mapping. These are
/// the pure inputs behind Mission Control Space identity: real CGS tables
/// are `[[String: Any]]` with release-dependent numeric shapes and a UUID
/// or "Main" display identifier. Injecting both lets the unit suite pin
/// the mapping without window-server symbols or attached displays.
final class LiveGatewayMappingTests: XCTestCase {
    // MARK: Space id parsing

    func testSpaceIDParsesEveryNumericShapeTheTableHasUsed() {
        XCTAssertEqual(
            LiveWindowGateway.spaceID(from: NSNumber(value: 7)),
            SpaceID(rawValue: 7))
        XCTAssertEqual(
            LiveWindowGateway.spaceID(from: UInt64(8)),
            SpaceID(rawValue: 8))
        XCTAssertEqual(
            LiveWindowGateway.spaceID(from: Int64(-1)),
            SpaceID(rawValue: UInt64(bitPattern: -1)))
        XCTAssertEqual(
            LiveWindowGateway.spaceID(from: "9"),
            SpaceID(rawValue: 9))
    }

    func testSpaceIDRejectsMissingAndNonNumericValues() {
        XCTAssertNil(LiveWindowGateway.spaceID(from: nil))
        XCTAssertNil(LiveWindowGateway.spaceID(from: "not a number"))
        XCTAssertNil(LiveWindowGateway.spaceID(from: ["nested": 1]))
    }

    // MARK: Display mapping

    private let twoDisplays: [[String: Any]] = [
        ["Display Identifier": "left-uuid"],
        ["Display Identifier": "right-uuid"],
    ]

    func testDisplayIDMatchesUUIDCaseInsensitively() {
        let uuids: [CGDirectDisplayID: String] = [
            10: "lEfT-uUiD",
            20: "RIGHT-UUID",
        ]
        let resolved = LiveWindowGateway.displayID(
            identifier: "right-uuid",
            among: twoDisplays,
            displayIDs: [10, 20],
            mainDisplayID: 99,
            uuidString: { uuids[$0] })
        XCTAssertEqual(resolved, 20)
    }

    func testDisplayIDResolvesMainToTheMainDisplay() {
        XCTAssertEqual(
            LiveWindowGateway.displayID(
                identifier: "Main",
                among: twoDisplays,
                displayIDs: [10, 20],
                mainDisplayID: 99,
                uuidString: { _ in nil }),
            99)
    }

    func testDisplayIDSingleDisplayFallbackKeepsAnUnknownIdentifier() {
        let display: [[String: Any]] = [["Display Identifier": "renamed-key"]]
        XCTAssertEqual(
            LiveWindowGateway.displayID(
                identifier: "renamed-key",
                among: display,
                displayIDs: [77],
                mainDisplayID: 99,
                uuidString: { _ in nil }),
            77)
        XCTAssertEqual(
            LiveWindowGateway.displayID(
                identifier: nil,
                among: display,
                displayIDs: [77],
                mainDisplayID: 99,
                uuidString: { _ in nil }),
            77)
    }

    func testDisplayIDUnknownAcrossMultipleDisplaysIsNil() {
        XCTAssertNil(
            LiveWindowGateway.displayID(
                identifier: "renamed-key",
                among: twoDisplays,
                displayIDs: [10, 20],
                mainDisplayID: 99,
                uuidString: { _ in nil }))
        XCTAssertNil(
            LiveWindowGateway.displayID(
                identifier: nil,
                among: twoDisplays,
                displayIDs: [10, 20],
                mainDisplayID: 99,
                uuidString: { _ in nil }))
    }

    func testDisplayIDEmptyLiveListHasNoFallback() {
        let display: [[String: Any]] = [["Display Identifier": "renamed-key"]]
        XCTAssertNil(
            LiveWindowGateway.displayID(
                identifier: "renamed-key",
                among: display,
                displayIDs: [],
                mainDisplayID: 99,
                uuidString: { _ in nil }))
    }

    // MARK: Space table rows

    func testSpacesMapEachKnownDisplayToItsCurrentSpace() {
        let table: [[String: Any]] = [
            [
                "Display Identifier": "left-uuid",
                "Current Space": ["id64": NSNumber(value: 11)],
            ],
            [
                "Display Identifier": "right-uuid",
                "Current Space": ["id64": "22"],
            ],
        ]
        let uuids: [CGDirectDisplayID: String] = [10: "left-uuid", 20: "right-uuid"]

        let mapped = LiveWindowGateway.spaces(
            from: table,
            displayIDs: [10, 20],
            mainDisplayID: 99,
            uuidString: { uuids[$0] })

        XCTAssertEqual(mapped, [10: SpaceID(rawValue: 11), 20: SpaceID(rawValue: 22)])
    }

    func testSpacesSkipMalformedRowsInsteadOfGuessing() {
        let table: [[String: Any]] = [
            [
                "Display Identifier": "left-uuid",
                "Current Space": ["id64": 11],
            ],
            [
                "Display Identifier": "unknown",
                "Current Space": ["id64": 22],
            ],
            [
                "Display Identifier": "right-uuid",
                "Current Space": [:],
            ],
            [
                "Display Identifier": "right-uuid",
            ],
            [
                "Display Identifier": "right-uuid",
                "Current Space": ["id64": "not a number"],
            ],
        ]
        let uuids: [CGDirectDisplayID: String] = [10: "left-uuid", 20: "right-uuid"]

        let mapped = LiveWindowGateway.spaces(
            from: table,
            displayIDs: [10, 20],
            mainDisplayID: 99,
            uuidString: { uuids[$0] })

        XCTAssertEqual(mapped, [10: SpaceID(rawValue: 11)])
    }

    func testSpacesSingleDisplayFallbackKeepsSpaceIdentity() {
        let table: [[String: Any]] = [
            [
                "Display Identifier": "renamed-key",
                "Current Space": ["id64": UInt64(42)],
            ]
        ]

        let mapped = LiveWindowGateway.spaces(
            from: table,
            displayIDs: [77],
            mainDisplayID: 99,
            uuidString: { _ in nil })

        XCTAssertEqual(mapped, [77: SpaceID(rawValue: 42)])
    }

    func testSpacesEmptyTableMapsNothing() {
        XCTAssertTrue(
            LiveWindowGateway.spaces(
                from: [],
                displayIDs: [10, 20],
                mainDisplayID: 99,
                uuidString: { _ in nil }).isEmpty)
    }
}
