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
        // AX commit/read discipline port (`src/ax_writer.rs`, `src/ax_reads.rs`).
        .target(
            name: "AXClient",
            dependencies: ["Geometry"],
            path: "Sources/AXClient"
        ),
        // Synchronous pipeline core: lexical passes, dirty flags, pump
        // cadence and scheduling predicates (`src/ecs/systems.rs`).
        .target(
            name: "EventCore",
            path: "Sources/EventCore"
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
        .executableTarget(
            name: "AXClientChecks",
            dependencies: ["AXClient", "Geometry"],
            path: "Tests/AXClientChecks"
        ),
        .executableTarget(
            name: "EventCoreChecks",
            dependencies: ["EventCore"],
            path: "Tests/EventCoreChecks"
        ),
    ]
)
