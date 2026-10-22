// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "StrataCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "StrataCore",
            targets: ["StrataCore"]
        ),
    ],
    targets: [
        .target(
            name: "StrataCore",
            path: "Sources/StrataCore"
        ),
        .testTarget(
            name: "StrataCoreTests",
            dependencies: ["StrataCore"],
            path: "Tests/StrataCoreTests"
        ),
    ]
)
