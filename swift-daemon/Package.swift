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
            "Commands",
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
        // PUC-Rio Lua 5.5.0, vendored for offline builds (see VENDORED.md).
        // Plain C, no codegen: compiles straight into the package.
        .target(
            name: "CLua",
            path: "Sources/CLua",
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("include")]
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
        // Live Lua bridge over the vendored PUC-Rio interpreter:
        // snapshot in, command strings out.
        .target(
            name: "LuaBridge",
            dependencies: ["CLua", "Scripting"],
            path: "Sources/LuaBridge"
        ),
        // Script-visible event taxonomy (`src/lua/convert.rs`).
        .target(
            name: "ScriptEvents",
            path: "Sources/ScriptEvents"
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
            name: "DaemonChecks",
            dependencies: ["Daemon", "Geometry", "Presentation"],
            path: "Tests/DaemonChecks"
        ),
        .executableTarget(
            name: "AnimationChecks",
            dependencies: ["Animation", "Geometry"],
            path: "Tests/AnimationChecks"
        ),
        .executableTarget(
            name: "ScrollChecks",
            dependencies: ["Scroll", "Geometry"],
            path: "Tests/ScrollChecks"
        ),
        .executableTarget(
            name: "XPCChecks",
            dependencies: ["PaneruXPC"],
            path: "Tests/XPCChecks"
        ),
        .executableTarget(
            name: "CommandsChecks",
            dependencies: ["Commands"],
            path: "Tests/CommandsChecks"
        ),
        .executableTarget(
            name: "FocusChecks",
            dependencies: ["Focus", "Commands", "Geometry", "Layout"],
            path: "Tests/FocusChecks"
        ),
        .executableTarget(
            name: "WorkspaceChecks",
            dependencies: ["Workspace", "Commands", "Geometry", "Layout"],
            path: "Tests/WorkspaceChecks"
        ),
        .executableTarget(
            name: "ConfigChecks",
            dependencies: ["Config"],
            path: "Tests/ConfigChecks"
        ),
        .executableTarget(
            name: "SessionChecks",
            dependencies: ["Session"],
            path: "Tests/SessionChecks"
        ),
        .executableTarget(
            name: "ScriptingChecks",
            dependencies: ["Scripting"],
            path: "Tests/ScriptingChecks"
        ),
        .executableTarget(
            name: "LuaBridgeChecks",
            dependencies: ["LuaBridge", "Scripting"],
            path: "Tests/LuaBridgeChecks"
        ),
        .executableTarget(
            name: "ScriptEventsChecks",
            dependencies: ["ScriptEvents"],
            path: "Tests/ScriptEventsChecks"
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
        // Fixed-duration tween math (`src/ecs/animation.rs`).
        .target(
            name: "Animation",
            dependencies: ["Geometry"],
            path: "Sources/Animation"
        ),
        // Trackpad/scroll physics (`src/ecs/scroll.rs`).
        .target(
            name: "Scroll",
            dependencies: ["Geometry"],
            path: "Sources/Scroll"
        ),
        // Serial daemon assembly wiring every module through the pass list.
        .target(
            name: "Daemon",
            dependencies: [
                "Geometry", "Layout", "AXClient", "EventCore",
                "Presentation", "Scripting",
            ],
            path: "Sources/Daemon"
        ),
        // XPC transport replacing the raw Mach bootstrap. Named PaneruXPC:
        // `XPC` alone collides with the system framework module.
        .target(
            name: "PaneruXPC",
            path: "Sources/PaneruXPC"
        ),
        // Command vocabulary + argv encoding (`crates/shared_types/commands.rs`,
        // `argv.rs`).
        .target(
            name: "Commands",
            path: "Sources/Commands"
        ),
        // Same-strip focus stepping + history (`src/commands.rs` focus half,
        // `src/ecs/focus.rs` history).
        .target(
            name: "Focus",
            dependencies: ["Commands", "Geometry", "Layout"],
            path: "Sources/Focus"
        ),
        // Virtual-workspace switch resolution (`src/ecs/workspace.rs`).
        .target(
            name: "Workspace",
            dependencies: ["Commands", "Geometry", "Layout"],
            path: "Sources/Workspace"
        ),
        // Resolved daemon configuration (`src/config.rs` getters).
        .target(
            name: "Config",
            path: "Sources/Config"
        ),
        // Session restore planning + state model (`src/ecs/restore.rs`,
        // `src/ecs/state.rs` shapes).
        .target(
            name: "Session",
            path: "Sources/Session"
        ),
    ]
)
