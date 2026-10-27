// swift-tools-version: 6.0
import PackageDescription

#if os(macOS)
let extraTargets: [Target] = [
    .executableTarget(
        name: "CursorBar",
        dependencies: ["PaceCore"],
        path: "Sources/CursorBar",
        linkerSettings: [.linkedLibrary("sqlite3")]
    ),
]
#else
let extraTargets: [Target] = []
#endif

let package = Package(
    name: "CursorBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "PaceCore",
            path: "Sources/PaceCore"
        ),
        .testTarget(
            name: "PaceCoreTests",
            dependencies: ["PaceCore"],
            path: "Tests/PaceCoreTests"
        ),
    ] + extraTargets
)
