// swift-tools-version: 5.9
import PackageDescription

// PaneruDaemon: native Swift port of the Paneru window-manager daemon.
// Grows slice by slice (Geometry -> Layout -> AXClient -> EventCore -> ...);
// the Rust daemon remains the shipped binary until cutover.
let package = Package(
    name: "PaneruDaemon",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PaneruDaemon", targets: ["Geometry", "Layout"]),
    ],
    targets: [
        // Real-time tap sidecar (C only: no Swift on the tap thread).
        // Public headers under Sources/CTapShim/include.
        .target(
            name: "CTapShim",
            path: "Sources/CTapShim",
            publicHeadersPath: "include"
        ),
        .target(
            name: "Geometry",
            path: "Sources/Geometry"
        ),
        // ECS-free strip model port (`src/ecs/layout.rs`).
        .target(
            name: "Layout",
            dependencies: ["Geometry"],
            path: "Sources/Layout"
        ),
        // Dependency-free check runners (this toolchain ships neither
        // XCTest nor swift-testing): `swift run --package-path
        // swift-daemon <Name>`. Fail nonzero on first mismatch.
        .executableTarget(
            name: "GeometryChecks",
            dependencies: ["Geometry"],
            path: "Tests/GeometryTests"
        ),
        .executableTarget(
            name: "LayoutChecks",
            dependencies: ["Layout", "Geometry"],
            path: "Tests/LayoutTests"
        ),
    ]
)
