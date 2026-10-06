// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JQEngine",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "JQEngine", targets: ["JQEngine"]),
        .executable(name: "jqswift", targets: ["jqswift"])
    ],
    targets: [
        .target(
            name: "JQEngine",
            path: "Sources/JQEngine"
        ),
        .executableTarget(
            name: "jqswift",
            dependencies: ["JQEngine"],
            path: "Sources/jqswift"
        ),
        .testTarget(
            name: "JQEngineTests",
            dependencies: ["JQEngine"],
            path: "Tests/JQEngineTests",
            // Read from disk by path (see FixturePaths), not bundled.
            exclude: ["Fixtures"]
        )
    ]
)
