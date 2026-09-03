// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "tiled",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "tiled",
            path: "Sources/tiled"
        ),
        .testTarget(
            name: "tiledTests",
            dependencies: ["tiled"],
            path: "Tests/tiledTests"
        ),
    ]
)
