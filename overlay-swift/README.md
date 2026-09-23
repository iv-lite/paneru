# PaneruOverlay — Swift overlay strangler

`libPaneruOverlay.dylib`, loaded at runtime by the Rust daemon (`dlopen`,
version-gated, per-slice fallback — see `src/overlay_bridge.rs`). The Rust
ECS keeps all truth computation (gates, rects, radii, on-screen sets); only
window/layer/paint code lives here.

## Build

```shell
swift build --package-path overlay-swift -c release
# → overlay-swift/.build/arm64-apple-macosx/release/libPaneruOverlay.dylib
```

## Try it (A/B, no rebuild of Rust needed beyond the feature)

```shell
cargo build --features swift-overlay
export PANERU_OVERLAY_DYLIB=$PWD/overlay-swift/.build/arm64-apple-macosx/release/libPaneruOverlay.dylib
# Rust build: binary runs the Rust overlay until the dylib loads.
# Force Rust path without rebuilding:
PANERU_SWIFT_OVERLAY=0 ./target/debug/paneru
```

The daemon logs `swift overlay backend active: true/false` at startup.

## Rollback

- Env `PANERU_SWIFT_OVERLAY=0` → byte-identical Rust path.
- Delete/rename the dylib → automatic fallback mid-tick with no crash.
- Cargo default features exclude the bridge entirely.

## Slices

1. Flash OSD (`Flash.swift`) — self-contained toast window.
2. Drop-preview ghost (`DropPreview.swift`) — armed-drag landing slot.
3. Borders (`Borders.swift`) — per-window pool, `O(changed)` sync.
4. Dim (`Dim.swift`) — fullscreen per-display surfaces with a GPU
   `CAShapeLayer` even-odd mask (fullscreen rect + rounded cutout hole):
   cutout motion updates a path, never re-rasters.

## C ABI (version 1)

`paneru_overlay_version`, `paneru_flash_show/remove`,
`paneru_drop_show/hide`, `paneru_borders_sync/hide`,
`paneru_dim_update/hide/remove`. Border items cross as raw bytes decoded
by explicit offsets (`BorderItemView.stride == 88`); Swift struct layout
is deliberately never relied upon. Bump the version on any change.
