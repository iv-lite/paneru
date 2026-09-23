// swift-tools-version: 5.9
import PackageDescription

// Swift overlay strangler for paneru: builds libPaneruOverlay.dylib, loaded
// at runtime by the Rust side (dlopen, version-gated, per-slice fallback).
// Language mode v5 by design: all entry points run on the main thread
// (asserted via dispatchPrecondition), so Swift 6 isolation adds noise
// without safety here.
let package = Package(
    name: "PaneruOverlay",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PaneruOverlay", type: .dynamic, targets: ["PaneruOverlay"]),
    ],
    targets: [
        .target(
            name: "PaneruOverlay",
            path: "Sources",
            swiftSettings: [.define("PANERU_OVERLAY")]
        ),
    ]
)
