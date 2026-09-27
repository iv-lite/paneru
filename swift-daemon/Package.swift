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
            name: "FrameParityChecks",
            dependencies: ["Daemon", "Commands", "Geometry", "Presentation"],
            path: "Tests/FrameParityChecks"
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
            name: "KeyChordsChecks",
            dependencies: ["KeyChords"],
            path: "Tests/KeyChordsChecks"
        ),
        .executableTarget(
            name: "SnippetChecks",
            dependencies: ["Snippets"],
            path: "Tests/SnippetChecks"
        ),
        .executableTarget(
            name: "ProviderChecks",
            dependencies: ["Providers", "Geometry"],
            path: "Tests/ProviderChecks"
        ),
        .executableTarget(
            name: "WorkerChecks",
            dependencies: ["Workers", "AXClient", "Geometry"],
            path: "Tests/WorkerChecks"
        ),
        .executableTarget(
            name: "DisplaysChecks",
            dependencies: ["Displays", "Geometry"],
            path: "Tests/DisplaysChecks"
        ),
        .executableTarget(
            name: "SessionChecks",
            dependencies: ["Session"],
            path: "Tests/SessionChecks"
        ),
        .executableTarget(
            name: "WindowSetChecks",
            dependencies: ["WindowSet", "Geometry"],
            path: "Tests/WindowSetChecks"
        ),
        .executableTarget(
            name: "StateQueryChecks",
            dependencies: ["StateQuery", "IPC"],
            path: "Tests/StateQueryChecks"
        ),
        .executableTarget(
            name: "LuaAPIChecks",
            dependencies: ["LuaAPI", "Commands", "IPC", "Scripting", "StateQuery", "WindowSet"],
            path: "Tests/LuaAPIChecks"
        ),
        .executableTarget(
            name: "ConfigFilesChecks",
            dependencies: ["ConfigFiles"],
            path: "Tests/ConfigFilesChecks"
        ),
        .executableTarget(
            name: "ScriptHostChecks",
            dependencies: [
                "Commands", "ScriptEvents", "ScriptHost", "Scripting",
                "StateQuery", "WindowSet",
            ],
            path: "Tests/ScriptHostChecks"
        ),
        .executableTarget(
            name: "PresenterChecks",
            dependencies: ["Presenter", "Presentation", "Geometry"],
            path: "Tests/PresenterChecks"
        ),
        .executableTarget(
            name: "MenuBarChecks",
            dependencies: ["MenuBar"],
            path: "Tests/MenuBarChecks"
        ),
        // Runnable Swift daemon (first slice): tick loop over live
        // providers, borders via Presenter, commands via the menubar.
        .executableTarget(
            name: "PaneruDaemon",
            dependencies: [
                "Commands", "Config", "ConfigFiles", "Daemon", "Geometry",
                "KeyChords", "LiveProviders", "MenuBar", "Presentation",
                "Presenter",
            ],
            path: "Sources/PaneruDaemon"
        ),
        .executableTarget(
            name: "LiveProvidersChecks",
            dependencies: ["LiveProviders", "Geometry"],
            path: "Tests/LiveProvidersChecks"
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
                "Presentation", "Scripting", "Commands", "Focus",
                "Workspace",
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
            dependencies: ["WindowSet"],
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
            dependencies: ["Commands", "KeyChords"],
            path: "Sources/Config"
        ),
        // Key-chord resolution (`resolve_chord`, modifier + keycode tables).
        .target(
            name: "KeyChords",
            path: "Sources/KeyChords"
        ),
        // Copy-Window-Rule snippet builder (`src/config/snippet.rs`).
        .target(
            name: "Snippets",
            path: "Sources/Snippets"
        ),
        // Live-window provider protocols + scriptable mock
        // (`manager::WindowApi` surface).
        .target(
            name: "Providers",
            dependencies: ["Geometry"],
            path: "Sources/Providers"
        ),
        // Worker shells: write drain + read pool over injected gateways
        // (`ax_writer::run`, `ax_reads::serve` control flow).
        .target(
            name: "Workers",
            dependencies: ["AXClient", "Geometry"],
            path: "Sources/Workers"
        ),
        // Display model: identity, insets, viewport derivation
        // (`src/manager/display.rs`, `ecs::DockPosition`).
        .target(
            name: "Displays",
            dependencies: ["Geometry"],
            path: "Sources/Displays"
        ),
        // Session restore planning + state model (`src/ecs/restore.rs`,
        // `src/ecs/state.rs` shapes).
        .target(
            name: "Session",
            path: "Sources/Session"
        ),
        // Script-side predicted layout tree + replay log
        // (`crates/shared_types/windowset.rs`).
        .target(
            name: "WindowSet",
            dependencies: ["Geometry"],
            path: "Sources/WindowSet"
        ),
        // Query documents + subscription events
        // (`crates/shared_types/state.rs`, `json.rs`).
        .target(
            name: "StateQuery",
            dependencies: ["IPC"],
            path: "Sources/StateQuery"
        ),
        // Live-runtime-free Lua client surface
        // (`crates/lua/src/lib.rs`, `client.rs` truth tables).
        .target(
            name: "LuaAPI",
            dependencies: ["Commands", "IPC", "Scripting", "StateQuery", "WindowSet"],
            path: "Sources/LuaAPI"
        ),
        // Config file discovery, defaults, deprecation, watch reduction
        // (`src/config.rs`, `src/manager.rs`, `src/ecs/triggers.rs`).
        .target(
            name: "ConfigFiles",
            path: "Sources/ConfigFiles"
        ),
        // Script worker mailbox without the thread or interpreter
        // (`src/lua/worker.rs`, `src/lua.rs`, `src/lua/world.rs` rules).
        .target(
            name: "ScriptHost",
            dependencies: [
                "Commands", "ScriptEvents", "Scripting", "StateQuery", "WindowSet",
            ],
            path: "Sources/ScriptHost"
        ),
        // AppKit presenter absorbed from overlay-swift/ (borders, dim,
        // flash, drop preview): direct calls replace the C ABI boundary.
        .target(
            name: "Presenter",
            dependencies: ["Geometry", "Presentation"],
            path: "Sources/Presenter"
        ),
        // Menu bar: pure indicator/menu model plus the live NSStatusItem
        // shell (`src/menubar.rs`).
        .target(
            name: "MenuBar",
            path: "Sources/MenuBar"
        ),
        // Live OS providers, proven on a permissioned host: AX
        // reads/writes/observers, event-tap lifecycle, writer coalescing,
        // launchd service runtime (`src/manager/windows.rs`,
        // `src/platform/input.rs`, `src/ax_writer.rs`,
        // `src/platform/service.rs`).
        .target(
            name: "LiveProviders",
            dependencies: ["Geometry"],
            path: "Sources/LiveProviders"
        ),
    ]
)
