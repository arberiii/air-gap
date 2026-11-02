// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AirGap",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic (rule matching, usage aggregation, formatting) so it can be unit tested.
        .target(name: "AirGapCore"),
        .executableTarget(
            name: "AirGap",
            dependencies: ["AirGapCore"]
        ),
        .testTarget(
            name: "AirGapCoreTests",
            dependencies: ["AirGapCore"]
        ),
    ]
)
