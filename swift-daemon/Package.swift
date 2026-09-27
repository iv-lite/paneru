// swift-tools-version: 5.9
import PackageDescription

// PaneruDaemon: native Swift port of the Paneru window-manager daemon.
// Grows slice by slice (Geometry -> Layout -> AXClient -> EventCore -> ...);
// the Rust daemon remains the shipped binary until cutover.
let package = Package(
    name: "PaneruDaemon",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PaneruDaemon", targets: [
            "Geometry", "Layout", "AXClient", "EventCore",
            "Presentation", "Scripting", "IPC", "Service",
        ]),
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
        // Overlay decision layer: sync plans, rest-equality, flash layout
        // (`src/overlay.rs`, `overlay-swift/Flash.swift`).
        .target(
            name: "Presentation",
            path: "Sources/Presentation"
        ),
        // Script-state store model (`crates/shared_types/script_state.rs`,
        // `script_value.rs`). LuaJIT itself links at packaging time.
        .target(
            name: "Scripting",
            path: "Sources/Scripting"
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
        .executableTarget(
            name: "PresentationChecks",
            dependencies: ["Presentation"],
            path: "Tests/PresentationChecks"
        ),
        .executableTarget(
            name: "IPCChecks",
            dependencies: ["IPC", "Scripting"],
            path: "Tests/IPCChecks"
        ),
        .executableTarget(
            name: "ServiceChecks",
            dependencies: ["Service"],
            path: "Tests/ServiceChecks"
        ),
        .executableTarget(
            name: "ScriptingChecks",
            dependencies: ["Scripting"],
            path: "Tests/ScriptingChecks"
        ),
        // Daemon↔client protocol shapes (`crates/shared_types/wire.rs`).
        .target(
            name: "IPC",
            dependencies: ["Scripting"],
            path: "Sources/IPC"
        ),
        // Launchd agent model (`src/platform/service.rs`, `assets/launchd.plist`).
        .target(
            name: "Service",
            path: "Sources/Service"
        ),
    ]
)
